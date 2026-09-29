# Architecture

## Process model

```
OpenDeck ──websocket (Stream Deck SDK protocol)──► MacControls (plugin, one process)
                                                     │
                                                     ├─► /usr/bin/perl nowplaying.pl libnowplaying.dylib
                                                     │     long-running; now-playing info out, commands in (stdin/stdout JSON lines)
                                                     │
                                                     ├─► MacControls --bluetooth get|on|off|devices
                                                     │     short-lived, spawned as its own "responsible process"
                                                     │
                                                     └─► /usr/bin/shortcuts, /usr/bin/pmset, /usr/bin/killall   (posix_spawn)
```

OpenDeck starts the plugin with `-port -pluginUUID -registerEvent -info` (see `App/main.swift`). The same binary also
runs as the Bluetooth helper and as the icon generator used by the build.

Everything in the plugin runs on the main queue: websocket events are dispatched there, timers use the main run loop,
and background work (subprocesses) reports back with `DispatchQueue.main.async`.

## Repository layout

```
Package.swift                    SwiftPM; links frameworks and embeds App/Info.plist into the binary
Sources/MacControls/
  App/
    main.swift                   argument routing (plugin / --bluetooth / --generate-icons), handler registration
    Info.plist                   bundle id + NSBluetoothAlwaysUsageDescription (embedded, not a resource)
  Core/
    Plugin.swift                 websocket connection, Instance, ActionHandler protocol, outbound events
    Subprocess.swift             posix_spawn wrapper (optionally "disclaimed")
    HoldRepeater.swift, Log.swift
  Rendering/
    Render.swift                 canvas + drawing primitives (symbols, fitted text, marquee, bars, sparklines)
    KeyLayouts.swift             complete key images (level, icon, image, toggle tile)
    KeyCatalog.swift             static icons/key images per action, plugin icon, --generate-icons
  System/                        macOS integrations, no OpenDeck knowledge
    SystemAudio.swift            CoreAudio: output volume/mute, devices, output switching, mic mute
    DisplayBrightness.swift      DisplayServices
    Keyboard.swift               keyboard backlight (CoreBrightness), input sources (TIS)
    NowPlaying.swift             client of the perl now-playing helper; media-key fallback
    ControlCenter.swift          switches + commands, Bluetooth helper entry point
    BluetoothBatteries.swift     accessory battery levels
    SystemStats.swift            CPU, memory, GPU, temperatures, network, disk, Mac battery
    ShortcutIcons.swift          shortcut icons from the Shortcuts database
    Input.swift                  synthetic keys, Accessibility menu presses
  Actions/                       one ActionHandler per action (group); rendering of their keys
Helpers/NowPlaying/              nowplaying.m (dylib) + nowplaying.pl (loader)
Resources/
  manifest.json                  actions, controllers, encoder layouts
  pi/                            property inspectors: pi.js (settings binding), pi.css, one page per action type
  layouts/media.json             custom dial layout: one full-size pixmap drawn by MediaAction
scripts/build.sh, install.sh, package.sh
```

## Plugin runtime

- **`Instance`** is one placed action (key or dial) with its settings; handlers keep per-instance state in dictionaries
  keyed by `context` and ask `Plugin.shared.instances(of:)` for their visible instances.
- **`ActionHandler`** methods have defaults, so handlers implement only what they need. `settingsChanged` defaults to
  `willAppear` (re-render).
- **Rendering**: keys are 144×144 PNG data URIs (`setImage`), deduplicated per instance so unchanged images are not
  resent. Dials use `setFeedback` with the manifest layout (`$B1` for level controls); the Media dial switches to
  `layouts/media.json` and draws the whole 200×100 segment itself, which allows artwork without caption and smooth
  scrolling text.
- **Polling vs. notifications**: CoreAudio listeners, MediaRemote notifications, NSWorkspace and TIS notifications
  where available; otherwise timers that only run while a relevant instance is visible (1 s stats, 2 s switches /
  brightness, 6 s Bluetooth, 30 s Bluetooth batteries, 10 fps only while text scrolls).
- **Property inspectors** bind form fields with `data-setting`/`data-default` (`pi.js`); `data-show`,
  `data-controller` and `data-for-action` control visibility. Lists (shortcuts, apps, devices, layouts, batteries) are
  requested with `sendToPlugin {request: …}` and answered with `sendToPropertyInspector`.

## Helper processes and why they exist

| Helper | Why |
|---|---|
| **Now playing** (`/usr/bin/perl` + `libnowplaying.dylib`) | Since macOS 15.4 MediaRemote only serves now-playing info to Apple-signed processes. Apple's perl may load our dylib and is allowed. Streams info (artwork only when it changes), accepts `togglePlayPause`, `next`, `previous`, `seek <s>`. Restarted with backoff; on failure the plugin falls back to synthetic media keys. |
| **Bluetooth** (`MacControls --bluetooth …`) | Bluetooth is TCC-protected and attributed to the *responsible process*: OpenDeck, whose Info.plist has no Bluetooth usage description, so TCC would kill the plugin. The helper is spawned with `responsibility_spawnattrs_setdisclaim`, becomes its own responsible process and uses the embedded Info.plist. |
| **`shortcuts`** via `posix_spawn` | Launched through Foundation's `Process` from under OpenDeck, `shortcuts run` reports "shortcut not found"; a plain `posix_spawn` works. |

## Private APIs

All are resolved at runtime (`dlopen`/`dlsym`/`NSClassFromString`), so a missing symbol disables only that feature.

| API | Used for | If it breaks |
|---|---|---|
| MediaRemote (`MRMediaRemoteGetNowPlayingInfo`, `SendCommand`, `SetElapsedTime`) via perl | now playing, transport, scrubbing | media keys, plain icons |
| DisplayServices `DisplayServicesSet/GetBrightness` | display brightness | N/A |
| CoreBrightness `KeyboardBrightnessClient`, `CBBlueLightClient`, `CBTrueToneClient` | keyboard backlight, Night Shift, True Tone | N/A |
| IOBluetooth `IOBluetoothPreferenceSetControllerPowerState`, `batteryPercent*` | Bluetooth switch, accessory batteries | N/A |
| SkyLight `SLSSetAppearanceThemeLegacy` | Dark Mode | alert |
| ApplicationServices `CoreDockSendNotification`, `CoreDockSetAutoHideEnabled` | Mission Control, Apps, Show Desktop, Dock | Mission Control/Apps fall back to opening the apps |
| login.framework `SACLockScreenImmediate` | Lock Screen | alert |
| IOHIDEventSystemClient (temperature sensors) | temperatures | "–" |
| WorkflowKit `WFWorkflowIconDrawer` + `~/Library/Shortcuts/Shortcuts.sqlite` | shortcut icons | generic icon |
| `com.apple.spotlight.toggle` (distributed notification) | Spotlight | – |

Not possible without Apple entitlements (verified): Low Power Mode (`_PMLowPowerMode` request never answered), Focus
(`DNDStateService` rejected over XPC). HomeKit is only available to signed Mac Catalyst apps.

## Adding an action

1. **Manifest** — add an entry to `Resources/manifest.json` with UUID `com.t01ik.macoscontrols.<id>`, controllers,
   `Icon: icons/<id>`, `States: [{Image: keys/<id>}]`, `PropertyInspectorPath`.
2. **Icons** — add `<id>` to `KeyCatalog.listIcons` and `KeyCatalog.defaultKeys` (rendered at build time).
3. **Handler** — implement `ActionHandler` in `Actions/`, with `actionIDs = ["<id>"]`; put macOS specifics in
   `System/`.
4. **Register** it in `App/main.swift`.
5. **Property inspector** — add `Resources/pi/<page>.html` using `pi.js`.
6. `scripts/install.sh`, then check `~/Library/Logs/MacControls.log`.

## Build

`scripts/build.sh`:
1. `swift build -c release --arch arm64 --arch x86_64` (universal; the linker embeds `App/Info.plist`)
2. `clang` builds the universal `libnowplaying.dylib`
3. copies `Resources/` and the perl loader into the bundle
4. runs `MacControls --generate-icons` to render `icons/` and `keys/`
5. ad-hoc signs the binary and the dylib

`scripts/package.sh` runs the build, validates the bundle and writes the release zip, marketplace icon and catalogue
entry to `dist/` (see [RELEASING.md](RELEASING.md)).

`scripts/install.sh` copies the bundle into OpenDeck's plugins folder and restarts OpenDeck with a clean environment
(like the Dock would), so the calling shell's variables do not leak into OpenDeck and its plugins.

## Gotchas

- OpenDeck does not restart a plugin that exits; restart OpenDeck after replacing the binary (install.sh does).
- Right after play/pause, MediaRemote briefly reports the item without artwork, and right after a seek it still reports
  the old position; both are smoothed over in `NowPlaying`.
- Stage Manager's `GloballyEnabled` preference is only read when WindowManager starts, hence the restart.
- TCC decisions for ad-hoc signed binaries are tied to the code signature, so rebuilding may re-prompt for Bluetooth.
- Encoder layouts are stored with the placed action in OpenDeck's profile; `MediaAction` re-sends `setFeedbackLayout`
  on appear so knobs placed with an older layout pick up the current one.
