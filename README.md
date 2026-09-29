# macOS Controls — OpenDeck plugin

Native macOS actions for [OpenDeck](https://github.com/nekename/OpenDeck), written in Swift with no third-party dependencies.

| Action | Keys | Dials |
|---|---|---|
| **Volume** | up / down (hold to repeat), mute, set to preset; shows level | turn = adjust, press = mute |
| **Display Brightness** | up / down, set to preset; shows level | turn = adjust, press = preset |
| **Media** | play/pause with artwork, title and progress; next; previous | turn = skip track, press = play/pause |
| **Mission Control**, **Apps (Launchpad)**, **Spotlight**, **Siri** | toggle / activate; symbol or system app icon | – |
| **Emoji & Symbols**, **Dictation** | open for the focused text field | – |
| **Run Shortcut** | runs a Shortcuts.app shortcut (optional text input) with its own icon, ✓ / ⚠ feedback | – |
| **Control Center** | switches with live state: Wi-Fi, Bluetooth, Stage Manager, Dark Mode, Night Shift, True Tone, mic mute, keep awake, Dock auto-hide; commands: lock, displays off, screensaver, sleep, show desktop | press = toggle |
| **Keyboard Brightness** | up / down, set to preset; shows level | turn = adjust, press = preset |
| **Audio Output** | switch to a device (lit while active) or cycle through devices | – |
| **Input Source** | next layout or a specific one; shows EN / RU… | – |
| **Open App** | opens / focuses an app (hides it if already in front); shows its icon and a running dot | – |
| **System Monitor** | CPU, RAM, GPU, battery (level, charging, time left), CPU/SSD/battery temperature, network ↓↑, disk R/W, with a 30 s graph | – |

## Build & install

Requires Xcode (or the Command Line Tools) with Swift 5.9+.

```bash
scripts/install.sh              # build, copy into OpenDeck's plugins folder, restart OpenDeck
scripts/build.sh                # only build → build/com.t01ik.macoscontrols.sdPlugin
```

Logs: `~/Library/Logs/MacControls.log`.

## Permissions

- **Bluetooth** switch: macOS asks once to allow **macOS Controls** to use Bluetooth (see below why it is not OpenDeck).
- **Emoji & Symbols** and **Dictation** need Accessibility, explained below.

Nothing else needs a permission. On first use macOS shows
*"OpenDeck.app wants to control this Mac and access your data"* — that is the **Accessibility** permission
(System Settings → Privacy & Security → Accessibility → OpenDeck).

This is unavoidable: macOS has no API to open the emoji picker or start dictation from another process, and the Globe (🌐)
key cannot be simulated, so the plugin has to press the *Edit* menu items of the focused app (or send ⌃⌘Space), which
requires Accessibility. The permission is granted to OpenDeck as a whole (plugins run as its child processes), so every
OpenDeck plugin can use it. If you do not use these two actions you can simply deny it — everything else works without it.

## How it works / limitations

- **Volume** — CoreAudio on the default output device. Outputs without software volume (HDMI/DisplayPort audio) show N/A,
  same as in macOS itself.
- **Brightness** — private `DisplayServices` framework, i.e. only displays macOS can dim itself: the built-in panel and
  Apple displays. Third-party monitors (DDC/CI) are intentionally not supported. Shows N/A when the lid is closed.
- **Now playing** — since macOS 15.4 the private MediaRemote framework only answers Apple-signed processes, so a small
  helper (`Helpers/NowPlaying`) is loaded into `/usr/bin/perl`, which is allowed. Transport commands go through the same
  helper; if a future macOS breaks this, the plugin falls back to synthetic media keys and plain icons. Right after
  play/pause MediaRemote briefly reports the item without artwork; the previous artwork is kept for the same item.
- **Mission Control / Apps** — Dock notifications (`com.apple.expose.awake`, `com.apple.launchpad.toggle`).
  **Spotlight** — the `com.apple.spotlight.toggle` distributed notification (works even with ⌘Space disabled).
  **Siri** — opens `/System/Applications/Siri.app`.
- **Emoji / Dictation** — there is no public API and the Globe key cannot be synthesised; the plugin presses the
  *Edit → Emoji & Symbols* / *Start Dictation* menu items AppKit adds to every app (so it needs an app with a text focus).
  Emoji falls back to ⌃⌘Space.
- **Shortcuts** — `/usr/bin/shortcuts run`, started with plain `posix_spawn`: launched through Foundation's `Process`
  from under OpenDeck it fails with "shortcut not found". Shortcuts are referenced by identifier (names are not unique).
  The shortcut's icon (colour + glyph) is read from `~/Library/Shortcuts/Shortcuts.sqlite` and drawn with the private
  WorkflowKit `WFWorkflowIconDrawer`, so it looks exactly like in the Shortcuts app; falls back to a symbol if that fails.
- **Open App** — `NSWorkspace`; the app list covers /Applications, /System/Applications and ~/Applications (plus one
  subfolder level).
- **Control Center** — Wi-Fi: CoreWLAN. Bluetooth: private `IOBluetoothPreferenceSetControllerPowerState`; Bluetooth is
  privacy-protected and OpenDeck's Info.plist has no Bluetooth usage description, so TCC would kill the plugin. Instead the
  plugin re-launches its own binary (`--bluetooth get|on|off`) with `responsibility_spawnattrs_setdisclaim`, making it
  its own responsible process; the binary embeds an Info.plist (`Support/Info.plist`) with the usage description.
  Ad-hoc signed rebuilds may make macOS ask again. Stage Manager: `com.apple.WindowManager GloballyEnabled` + restarting
  WindowManager (it only reads the setting at launch; brief flicker). Dark Mode: SkyLight `SLSSetAppearanceThemeLegacy`.
  Night Shift / True Tone: CoreBrightness `CBBlueLightClient` / `CBTrueToneClient`. Mic: CoreAudio input mute (or level
  0). Keep awake: an IOPMAssertion held by the plugin. Dock: `CoreDockSetAutoHideEnabled`. Lock: `SACLockScreenImmediate`.
  Displays off / sleep: `pmset displaysleepnow` / `sleepnow`. Show desktop: Dock notification.
- **Not possible without Apple's private entitlements**: Low Power Mode, Focus (use a Shortcut with *Set Focus*), AirDrop,
  AirPlay, Personal Hotspot. HomeKit is only available to signed Mac Catalyst apps — use Shortcuts' Home actions.
- **Keyboard Brightness** — CoreBrightness `KeyboardBrightnessClient`. **Audio Output** — CoreAudio default output
  (and system sound output). **Input Source** — Text Input Sources (TIS) API.
- **Temperatures** — private IOHIDEventSystem sensors (no root needed). CPU = average of the SoC `tdie` sensors.

## Layout

```
Sources/MacControls/
  Core/      websocket protocol, rendering, hold-to-repeat, posix_spawn helper
  System/    CoreAudio, DisplayServices, MediaRemote client, stats, input/Accessibility
  Actions/   one handler per action group
Helpers/NowPlaying/   Objective-C helper loaded into /usr/bin/perl
Support/Info.plist    embedded into the binary (bundle id + Bluetooth usage description)
Plugin/               manifest.json and property inspectors (pi/)
scripts/              build.sh, install.sh
```
