# Driftdock

A second dock for your Mac with live widgets. It floats beside (or instead of) the macOS Dock and holds a clock, weather, your pinned apps and folders, now playing, system stats, to-dos, a focus timer, clipboard history, quick search and quick toggles.

Native Swift + SwiftUI, no dependencies, no accounts. Requires macOS Sonoma 14 or later.

## Build and run

You need the Xcode Command Line Tools (full Xcode also works):

```bash
xcode-select --install   # skip if already installed
```

Then from this folder:

```bash
./build.sh --install
```

That compiles a release build, assembles `Driftdock.app`, signs it ad-hoc, copies it to `/Applications` and launches it. Use `./build.sh` without the flag to just build into `build/`.

Driftdock has no Dock icon of its own. Look for the dock icon in the menu bar for Show/Hide, Settings and Quit. You can also right-click the dock itself for Settings.

## Widgets

| Widget | What it does |
|---|---|
| Clock | Digital, analog or both; 12/24-hour, seconds, typeface and weight, date format, and a second time zone. Click it for one-click styles (Classic, Bold, Thin, Serif, Mono, Analog, Both) and colors; more in Settings → Clock |
| Weather | Current temp plus a 3-day forecast for where you are (or a city you pick), from Open-Meteo with no API key. Click it to open the Weather app |
| Apps & Folders | Pinned apps plus every open app (like the macOS Dock), with running dots and hover magnify. Folders open as a grid of their newest items. Drag apps or folders onto it to pin them. The Trash sits at the end: drop files on it, right-click to empty |
| Recent Screenshots | Thumbnails of screenshots (and screen recordings) from the last few minutes. Drag them into any app, click for a big preview, hover and press × to remove. Only appears when there's a fresh screenshot |
| Now Playing | Track, artist and artwork from Music or Spotify, with play/pause/skip. Hides itself when nothing is playing (optional). Right-click to pick which app opens when nothing is playing |
| System Stats | CPU, memory, battery and chip temperature rings (falls back to Cool/Warm/Hot). Click to open Activity Monitor |
| To-dos | Quick task list, saved locally |
| Focus Timer | 25/5 Pomodoro with a chime at the end of each phase |
| Clipboard | Last 25 copied snippets. Skips anything password managers mark as concealed |
| Search | Type an app name and press Return to open it, or search the web |
| AirPods & Devices | Battery for connected AirPods (L/R/case) and other Bluetooth devices. Only appears while one is connected |
| Quick Toggles | Dark mode, mute, screenshot, sleep display |

To remove a widget, right-click it → **Remove**, use right-click → **Remove Widget**, or press its red **–** in Rearrange mode. Add one back with right-click → **Add Widget**. To reorder, right-click the dock → **Rearrange Widgets**, then drag a widget onto another to take its place (or drag rows in Settings → Widgets).

## Notch

On MacBooks with a notch, Driftdock turns it into a mini control center (inspired by Boring Notch):

- **Closed:** blends into the real notch. While music plays, album art and a visualizer that moves with the music (bass on the left, treble on the right) peek out on each side; while charging, the battery shows instead.
- **Open (hover or click):** a black panel drops down with a big Now Playing player (artwork, seekable progress, transport controls, album-art glow) and a floating tab bar for **File Tray**, **Calendar**, **Tools**, **Volume Mixer** and **Mirror**.
- Drag a file toward the notch and it opens straight to the shelf.

- **Live activities** while closed: volume (with level), downloads, focus timer countdown, music, "Charging 80%", files in the shelf, and quick confirmations like "Copied".
- **Banners** that grow the notch for a moment: Full Battery, AirPods connected (L/R/case), focus session finished.
- **Dynamic Island** on displays without a notch.
- **Replaces the macOS volume and brightness overlays:** Driftdock handles those keys itself (Shift+Option for fine steps), so only the notch shows the change. Needs Accessibility.
- **AirPods connected card:** device, name, and animated battery rings for left, right and case.
- **Today** tab: calendar, weather and to-dos.
- Droppy 14-style motion: the panel drops out of the notch with a soft blur, the tab bar pops out of the notch, and live activities shrink in place.
- **Timers** tab and live activity: timers (orange ring and countdown) and stopwatches; start them here, from Tools, or by typing "timer 10m" in the launcher.
- **Calls:** while FaceTime, Zoom, Teams, Meet, Discord, Slack or WhatsApp is using the mic, the notch shows a green call timer and a mic mute button. (macOS doesn't let apps see incoming calls before they're answered.)
- **Customizable tab bar:** drag tabs to reorder, right-click to remove, + to add (or Settings → Notch → Tabs).
- Stays visible while swiping between Spaces and full-screen apps.
- **Tools** tab: Stay Awake, focus timer, color picker (copies the hex), launcher, clipboard, screenshot, dark mode, File Tray.
- **Black or Glass** finish when open.

Everything is configurable in Settings → Notch, including a fake notch for Macs that don't have one.

## Extras (inspired by Droppy)

- **File Tray:** shake a file while dragging it and a tray appears under the pointer. Drop to hold, drag out later. It shares files with the notch shelf.
- **Actions** on the shelf/tray (all on-device): convert images (PNG/JPEG/HEIC/TIFF), compress images, remove background, copy text (OCR), compress video, make GIF, combine into PDF, zip, share. Click items to pick which ones an action uses; results are saved next to the originals.
- **Launcher (⌥Space):** apps, commands, quick math, web search.
- **Clipboard Manager (⇧⌘V):** text and images, pin to the top, rename, copy text out of images, drag entries into other apps; optionally pastes for you (needs Accessibility).
- **Voice Transcribe (⌥⇧D):** live dictation that streams into the notch as you speak; stopping copies the transcript.

- **Window snapping:** ⌃⌥←/→/↑/↓ for halves, ⌃⌥↩ maximize, ⌃⌥C center, ⌃⌥U/I/J/K quarters, ⌃⌥D/F/G thirds, ⌃⌥E/T two-thirds, ⌃⌥⌫ undo. Or drag a window to a screen edge/corner and a preview shows where it lands. Needs Accessibility.
- **AirPods & device battery:** left, right and case for AirPods (one level for keyboards, mice, headphones) in the dock, the notch, and a quick note when something connects.
- **Mixer (macOS 14.2+), like eqMac:** menu bar → Volume Mixer, or the notch's mixer tab. System volume and **Boost** (up to 2×), **Balance**, an **App Mixer** with a 0–200% fader per app, a **10-band EQ** (32 Hz–16 kHz, ±12 dB) with presets, saved custom presets, preamp and auto-preamp, and an **output device** picker. Nothing is processed while everything is at its default; changing something asks for System Audio Recording permission.

Everything here can be turned off in Settings → Extras.

## Permissions

macOS asks the first time a feature needs it:

- **Automation → Music / Spotify**: Now Playing.
- **Automation → System Events**: the dark-mode toggle.
- **Location Services**: weather for your current location.
- **Calendars** and **Camera**: the notch's calendar and mirror, only if you use them.
- **Files and Folders → Desktop** (or wherever screenshots are saved): Recent Screenshots. **Downloads**: download progress in the notch.
- **Accessibility**: window snapping, and auto-paste for clipboard history.
- **Bluetooth**: AirPods and device battery.
- **Microphone** and **Speech Recognition**: Voice Transcribe.
- **Screen & System Audio Recording**: the music visualizer, and per-app volume once you change an app's volume.

If you clicked "Don't Allow", re-enable it in System Settings → Privacy & Security.

**Permissions sticking between builds:** `build.sh` signs Driftdock with a private certificate it creates on your Mac the first time (`setup-signing.sh`), so macOS remembers Accessibility and other permissions across rebuilds. If macOS asks for keychain access the first time it signs, click **Always Allow**.

## Customizing

Settings → General controls the screen edge (bottom, top, left, right), alignment, distance from the edge, size, backdrop style (glass, dark, light, tinted), accent color, corner radius, auto-hide and open-at-login.

**Multiple monitors:** Settings → General → Displays picks where the dock shows up: the main display, following the pointer like the macOS Dock (push against the bottom edge of any display and it moves there), every display at once, or one specific monitor.

To use Driftdock as your only dock, turn on **Replace the macOS Dock** in Settings → General. That hides the system Dock and makes Driftdock slide off the screen edge, coming back when you push the pointer against it. Quitting Driftdock from its menu puts the system Dock back.

If Driftdock ever crashes while replacing the Dock, get the system Dock back with:

```bash
defaults delete com.apple.dock autohide-delay; killall Dock
```

## Project layout

```
Sources/Driftdock/
  DriftdockApp.swift      app entry, menu bar item, settings window
  AppState.swift          settings model, persisted to UserDefaults
  DockPanel.swift         floating non-activating panel, positioning, auto-hide
  DockRootView.swift      dock layout, backdrop, Tile container, shared helpers
  SettingsView.swift      settings tabs
  Widgets/                one file per widget group
  Notch/                  notch window, open/closed views, shelf, calendar, mirror, tools
  Extras/                 launcher, clipboard picker, file tray, file actions, live activities, hot keys
Resources/                Info.plist and app icon
build.sh                  builds the .app bundle
```

To add a widget: add a case to `WidgetKind` in `AppState.swift`, write a view that wraps its content in `Tile(span:)`, and return it from `WidgetView` in `DockRootView.swift`.
