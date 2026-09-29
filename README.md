# macOS Controls — OpenDeck plugin

Native macOS actions for [OpenDeck](https://github.com/nekename/OpenDeck): volume, media, brightness, Control Center
switches, launchers, Shortcuts, apps and a hardware monitor. Written in Swift, no third-party dependencies, no root.

Keys show live state (levels, now playing, on/off, stats); actions with dial support work on encoders too
(e.g. Ajazz AKP05 / Mirabox N4, Stream Deck +).

## Actions

| Action | Keys | Dials |
|---|---|---|
| **Volume** | up / down (hold to repeat), mute, set to preset; shows the level | turn = adjust, press = mute |
| **Display Brightness** | same, for the built-in display and Apple displays | turn = adjust, press = preset |
| **Keyboard Brightness** | same, for the built-in keyboard backlight | turn = adjust, press = preset |
| **Media** | play/pause with artwork, title and progress; next; previous | turn = skip tracks or scrub, press = play/pause |
| **Audio Output** | switch to a device (lit while active) or cycle through devices | – |
| **Input Source** | next keyboard layout or a specific one (EN / RU …) | – |
| **Control Center** | switches with live state: Wi-Fi, Bluetooth, Stage Manager, Dark Mode, Night Shift, True Tone, mic mute, keep awake, Dock auto-hide · commands: lock, displays off, screensaver, sleep, show desktop | press = toggle |
| **Mission Control**, **Apps** (Launchpad), **Spotlight**, **Siri** | toggle / activate; SF Symbol or the system app icon | – |
| **Emoji & Symbols**, **Dictation** | open for the focused text field | – |
| **Run Shortcut** | runs a Shortcuts shortcut (optional text input) with its own icon; ✓ / ⚠ feedback | – |
| **Open App** | opens / focuses an app, hides it if already in front; app icon and running dot | – |
| **System Monitor** | CPU, RAM, GPU, battery (Mac or a Bluetooth device: keyboard, mouse, AirPods L/R/Case), CPU / SSD / battery temperature, network ↓↑, disk R/W; optional 30 s graph | – |

Every action has a property inspector in OpenDeck with its options (step sizes, presets, captions on/off, icon style,
scrolling of long titles, …).

## Requirements

- macOS 13 or later (developed and tested on macOS 27, Apple Silicon)
- [OpenDeck](https://github.com/nekename/OpenDeck) 2.x
- Xcode or the Command Line Tools (Swift 5.9+) to build

## Install

**From a release:** download `macos-controls.plugin.zip` from the latest GitHub release, then in OpenDeck open
*Plugins → Install from file* and pick it. Once listed in the OpenAction Marketplace, install it from OpenDeck's plugin
browser instead; OpenDeck then also offers updates.

**From source:**

```bash
scripts/install.sh      # build, copy into OpenDeck's plugins folder, restart OpenDeck
scripts/build.sh        # only build → build/com.t01ik.macoscontrols.sdPlugin
scripts/package.sh      # build + validate + release artifacts → dist/  (see docs/RELEASING.md)
```

The actions appear in the **macOS** category.

## Permissions

Only these features ask for permission, each once:

| Feature | Prompt | Why |
|---|---|---|
| **Emoji & Symbols**, **Dictation** | *OpenDeck wants to control this Mac* (Accessibility) | macOS has no API to open these for another app and the 🌐 key cannot be simulated, so the plugin clicks the *Edit* menu items of the focused app. Granted to OpenDeck as a whole. |
| **Bluetooth** switch and Bluetooth battery levels | *macOS Controls wants to use Bluetooth* | Bluetooth is privacy-protected; a small helper asks for it under the plugin's own name. May be asked again after rebuilding. |

Everything else works without any permission. You can deny a prompt; only that feature stops working.

## Limitations

- **Brightness** only for displays macOS can dim itself (built-in, Apple displays); third-party monitors are not
  supported. Shows *N/A* with the lid closed. Same for **True Tone** and **Keyboard Brightness**.
- **Volume** is *N/A* for outputs without software volume (HDMI / DisplayPort audio), as in macOS.
- **Now playing / scrubbing** rely on a private framework that macOS restricts; see
  [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). Scrubbing works only with apps that support seeking.
- **Stage Manager** switching restarts the window manager — a brief flicker.
- **Not possible** without Apple's private entitlements: Low Power Mode, Focus (use a shortcut with *Set Focus*),
  AirDrop, AirPlay, Personal Hotspot. **HomeKit**: use Shortcuts' Home actions with *Run Shortcut*.

## Troubleshooting

- **Log:** `~/Library/Logs/MacControls.log` (recreated on every start). OpenDeck's own log is in
  `~/Library/Logs/opendeck/`.
- **Keys stopped updating:** OpenDeck does not restart a plugin that quit — restart OpenDeck.
- **Emoji / Dictation do nothing:** check System Settings → Privacy & Security → Accessibility → OpenDeck, and that the
  front app has a text field focused.
- **Bluetooth switch shows N/A:** allow *macOS Controls* in System Settings → Privacy & Security → Bluetooth.

## Development

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for how the plugin is built, the helper processes, the private APIs
it uses and how to add an action, and [docs/RELEASING.md](docs/RELEASING.md) for publishing a release and the
marketplace listing.

```
Sources/MacControls/   Swift plugin (App, Core, Rendering, System, Actions)
Helpers/NowPlaying/    Objective-C now-playing helper, loaded into /usr/bin/perl
Resources/             manifest.json, property inspectors (pi/), dial layouts — copied into the bundle
scripts/               build.sh, install.sh, package.sh
docs/                  ARCHITECTURE.md, RELEASING.md
```
