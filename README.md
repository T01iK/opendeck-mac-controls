# macOS Controls — OpenDeck plugin

Native macOS actions for [OpenDeck](https://github.com/nekename/OpenDeck), written in Swift with no third-party dependencies.

| Action | Keys | Dials |
|---|---|---|
| **Volume** | up / down (hold to repeat), mute, set to preset; shows level | turn = adjust, press = mute |
| **Display Brightness** | up / down, set to preset; shows level | turn = adjust, press = preset |
| **Media** | play/pause with artwork, title and progress; next; previous | turn = skip track, press = play/pause |
| **Mission Control**, **Apps (Launchpad)**, **Spotlight**, **Siri** | toggle / activate | – |
| **Emoji & Symbols**, **Dictation** | open for the focused text field | – |
| **Run Shortcut** | runs a Shortcuts.app shortcut (optional text input), ✓ / ⚠ feedback | – |
| **System Monitor** | CPU, RAM, GPU, CPU/SSD/battery temperature, network ↓↑, disk R/W, with a 30 s graph | – |

## Build & install

Requires Xcode (or the Command Line Tools) with Swift 5.9+.

```bash
scripts/install.sh              # build, copy into OpenDeck's plugins folder, restart OpenDeck
scripts/build.sh                # only build → build/com.t01ik.macoscontrols.sdPlugin
```

Logs: `~/Library/Logs/MacControls.log`.

## Permissions

- **Accessibility** for OpenDeck (System Settings → Privacy & Security → Accessibility) — needed by *Emoji & Symbols*,
  *Dictation*, and the media-key fallback. macOS prompts on first use.

## How it works / limitations

- **Volume** — CoreAudio on the default output device. Outputs without software volume (HDMI/DisplayPort audio) show N/A,
  same as in macOS itself.
- **Brightness** — private `DisplayServices` framework, i.e. only displays macOS can dim itself: the built-in panel and
  Apple displays. Third-party monitors (DDC/CI) are intentionally not supported. Shows N/A when the lid is closed.
- **Now playing** — since macOS 15.4 the private MediaRemote framework only answers Apple-signed processes, so a small
  helper (`Helpers/NowPlaying`) is loaded into `/usr/bin/perl`, which is allowed. Transport commands go through the same
  helper; if a future macOS breaks this, the plugin falls back to synthetic media keys and plain icons.
- **Mission Control / Apps** — Dock notifications (`com.apple.expose.awake`, `com.apple.launchpad.toggle`).
  **Spotlight** — the `com.apple.spotlight.toggle` distributed notification (works even with ⌘Space disabled).
  **Siri** — opens `/System/Applications/Siri.app`.
- **Emoji / Dictation** — there is no public API and the Globe key cannot be synthesised; the plugin presses the
  *Edit → Emoji & Symbols* / *Start Dictation* menu items AppKit adds to every app (so it needs an app with a text focus).
  Emoji falls back to ⌃⌘Space.
- **Shortcuts** — `/usr/bin/shortcuts run`.
- **Temperatures** — private IOHIDEventSystem sensors (no root needed). CPU = average of the SoC `tdie` sensors.

## Layout

```
Sources/MacControls/
  Core/      websocket protocol, rendering, hold-to-repeat
  System/    CoreAudio, DisplayServices, MediaRemote client, stats, input/Accessibility
  Actions/   one handler per action group
Helpers/NowPlaying/   Objective-C helper loaded into /usr/bin/perl
Plugin/               manifest.json and property inspectors (pi/)
scripts/              build.sh, install.sh
```
