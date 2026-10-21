import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            WidgetSettings().tabItem { Label("Widgets", systemImage: "square.grid.2x2") }
            AppsSettings().tabItem { Label("Apps", systemImage: "app.badge") }
            ClockSettings().tabItem { Label("Clock", systemImage: "clock") }
            WeatherSettings().tabItem { Label("Weather", systemImage: "cloud.sun") }
            NotchSettings().tabItem { Label("Notch", systemImage: "rectangle.topthird.inset.filled") }
            ExtrasSettings().tabItem { Label("Extras", systemImage: "wand.and.stars") }
            GlideSettings().tabItem { Label("Glide", systemImage: "cursorarrow.motionlines") }
        }
        .frame(width: 640, height: 640)
    }
}

// MARK: - General

struct GeneralSettings: View {
    @EnvironmentObject var state: AppState
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    private var displayHelp: String {
        switch state.config.display {
        case DisplayChoice.follow:
            return "Push the pointer against the dock's edge on any display and the dock moves there."
        case DisplayChoice.all:
            return "Each display gets its own dock. Each one shrinks to fit its screen."
        case DisplayChoice.main:
            return "The display with the menu bar."
        default:
            return "Stays on this display. If it's unplugged, the dock moves to the main display."
        }
    }

    var body: some View {
        Form {
            Section("Position") {
                Picker("Screen edge", selection: $state.config.edge) {
                    ForEach(DockEdge.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Alignment", selection: $state.config.align) {
                    ForEach(DockAlign.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                LabeledSlider(title: "Distance from edge", value: $state.config.margin, range: 0...60, format: "%.0f pt")
                Toggle("Replace the macOS Dock", isOn: $state.config.replaceSystemDock)
                    .onChange(of: state.config.replaceSystemDock) { _, on in
                        if on {
                            SystemDock.hide()
                            state.config.autoHide = true
                        } else {
                            SystemDock.restore()
                        }
                    }
                Toggle("Automatically hide and show (push the pointer against the edge)", isOn: $state.config.autoHide)
            }

            Section("Displays") {
                Picker("Show Driftdock on", selection: $state.config.display) {
                    Text("Main display").tag(DisplayChoice.main)
                    Text("Follow the pointer, like the macOS Dock").tag(DisplayChoice.follow)
                    Text("Every display").tag(DisplayChoice.all)
                    let screens = DisplayChoice.labeledScreens()
                    if screens.count > 1 {
                        Divider()
                        ForEach(screens.map { $0.label }, id: \.self) { label in
                            Text(label).tag(DisplayChoice.screenPrefix + label)
                        }
                    }
                }
                Text(displayHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Look") {
                LabeledSlider(title: "Size", value: $state.config.scale, range: 0.6...1.5, format: "%.2f×")
                if state.fitScale < 0.999 {
                    Text("Shrunk to \(Int((state.fitScale * 100).rounded()))% so everything fits on screen. Turn off a widget or two to make it bigger.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Picker("Backdrop", selection: $state.config.backdrop) {
                    ForEach(Backdrop.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Use system accent color", isOn: $state.config.useSystemAccent)
                ColorPicker("Custom accent color", selection: Binding(
                    get: { Color(hex: state.config.accentHex) },
                    set: { state.config.accentHex = $0.hexString }
                ), supportsOpacity: false)
                .disabled(state.config.useSystemAccent)
                LabeledSlider(title: "Corner radius", value: $state.config.cornerRadius, range: 8...34, format: "%.0f pt")
            }

            Section("System") {
                Toggle("Open Driftdock at login", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            loginError = nil
                        } catch {
                            loginError = "Couldn't change this. Move Driftdock to /Applications and try again."
                        }
                    }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Restart Driftdock")
                        Text("Quits and reopens the app. Use it if the dock gets stuck or looks wrong.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Force Restart") { AppRestarter.restart() }
                }
                Text("When Driftdock replaces the macOS Dock, quitting Driftdock brings the system Dock back automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String

    var body: some View {
        HStack {
            Text(title)
            Slider(value: $value, in: range)
            Text(String(format: format, value))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
        }
    }
}

// MARK: - Widgets

struct WidgetSettings: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Turn widgets on or off. Drag rows to reorder.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button(state.arranging ? "Done Rearranging" : "Rearrange on the Dock") {
                    state.arranging.toggle()
                }
            }
            List {
                ForEach($state.config.widgets) { $entry in
                    HStack(spacing: 10) {
                        Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                        Image(systemName: entry.kind.symbol)
                            .frame(width: 22)
                            .foregroundStyle(state.accent)
                        Toggle(entry.kind.title, isOn: $entry.enabled)
                            .toggleStyle(.checkbox)
                        Spacer()
                    }
                    .padding(.vertical, 3)
                }
                .onMove { from, to in
                    state.config.widgets.move(fromOffsets: from, toOffset: to)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))

            GroupBox("System Stats") {
                Toggle("Show the chip temperature (uses your weather °F/°C setting)", isOn: $state.config.statsShowTemp)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Now Playing") {
                HStack {
                    Text("When nothing is playing, open")
                    Picker("", selection: $state.config.idleMusicApp) {
                        Text("Music").tag("com.apple.Music")
                        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") != nil {
                            Text("Spotify").tag("com.spotify.client")
                        }
                        if !["com.apple.Music", "com.spotify.client"].contains(state.config.idleMusicApp) {
                            Text(NowPlayingModel.idleAppName).tag(state.config.idleMusicApp)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                    Button("Other App…") { chooseIdleApp() }
                }
                .padding(6)
                Toggle("Hide the Now Playing widget when nothing is playing", isOn: $state.config.hideIdleMusic)
                    .padding(.horizontal, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Recent Screenshots") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Keep screenshots on the dock for")
                        Picker("", selection: $state.config.screenshotMinutes) {
                            Text("1 minute").tag(1.0)
                            Text("3 minutes").tag(3.0)
                            Text("5 minutes").tag(5.0)
                            Text("10 minutes").tag(10.0)
                        }
                        .labelsHidden()
                        .frame(width: 130)
                    }
                    Toggle("Include screen recordings", isOn: $state.config.includeRecordings)
                    Toggle("Pop the dock up when you take a screenshot (with auto-hide)", isOn: $state.config.revealOnScreenshot)
                    Text("Watching \(ScreenshotModel.folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")). Drag a thumbnail into any app, click it for a preview, or hover and press × to remove it from the dock.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(!state.config.widgets.contains { $0.kind == .screenshots && $0.enabled })
            }

            HStack {
                Text("Search engine")
                Picker("", selection: $state.config.searchEngine) {
                    Text("Google").tag("google")
                    Text("DuckDuckGo").tag("duckduckgo")
                }
                .labelsHidden()
                .frame(width: 160)
                Spacer()
                Button("Reset widgets") {
                    state.config.widgets = Config().widgets
                }
            }
        }
        .padding(20)
    }

    /// Pick any app (Apple Music, Spotify, TIDAL, YouTube Music…) to open when nothing is playing.
    private func chooseIdleApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier {
            state.config.idleMusicApp = id
        }
    }
}

// MARK: - Apps

struct AppsSettings: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox("Open apps") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Show open apps in the dock", isOn: $state.config.showOpenApps)
                    Group {
                        Toggle("Separate pinned and open apps with a divider", isOn: $state.config.showAppDivider)
                        HStack {
                            Text("Order open apps by")
                            Picker("", selection: $state.config.openAppsSort) {
                                Text("Launch order").tag("launch")
                                Text("Name").tag("name")
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(width: 200)
                        }
                    }
                    .disabled(!state.config.showOpenApps)
                    .padding(.leading, 18)
                    Divider()
                    Toggle("Show a dot under open apps", isOn: $state.config.showRunningDots)
                    Toggle("Show the Trash at the end", isOn: $state.config.showTrash)
                    Toggle("Dim apps that are hidden (⌘H)", isOn: $state.config.dimHiddenApps)
                    Toggle("Clicking the app you're using hides it", isOn: $state.config.clickActiveToHide)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text("Pinned apps and folders. Drag onto the dock to add, or right-click an open app → Keep in Dock.")
                .foregroundStyle(.secondary)
            List {
                ForEach(state.config.pinned) { item in
                    HStack(spacing: 10) {
                        Image(nsImage: IconCache.icon(for: item.path)).resizable().frame(width: 24, height: 24)
                        Text(URL(fileURLWithPath: item.path).deletingPathExtension().lastPathComponent)
                        Spacer()
                        Button {
                            state.config.pinned.removeAll { $0.id == item.id }
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove")
                    }
                    .padding(.vertical, 2)
                }
                .onMove { from, to in
                    state.config.pinned.move(fromOffsets: from, toOffset: to)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))

            HStack {
                Button("Add App or Folder…", action: addItems)
                Spacer()
                Button("Restore defaults") { state.config.pinned = Config.defaultPinned }
            }
        }
        .padding(20)
    }

    private func addItems() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Pin"
        if panel.runModal() == .OK {
            state.addPinned(panel.urls)
        }
    }
}

// MARK: - Weather

struct WeatherSettings: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var location = LocationModel.shared
    @State private var query = ""
    @State private var status: String?
    @State private var searching = false

    private struct GeoResponse: Decodable {
        struct Place: Decodable {
            let name: String
            let latitude: Double
            let longitude: Double
            let admin1: String?
            let country_code: String?
        }
        let results: [Place]?
    }

    var body: some View {
        Form {
            Section("Location") {
                Toggle("Use my current location", isOn: $state.config.useCurrentLocation)
                if state.config.useCurrentLocation {
                    if location.isDenied {
                        HStack {
                            Text("Location access is off for Driftdock, so the city below is used.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Open Settings") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .controlSize(.small)
                        }
                    } else if let place = location.placeName {
                        LabeledContent("Now showing", value: place)
                    } else {
                        Text("Finding your location…").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section(state.config.useCurrentLocation ? "Fallback city (when location isn't available)" : "City") {
                LabeledContent("Current", value: state.config.cityName)
                HStack {
                    TextField("City name", text: $query)
                        .onSubmit { Task { await lookUp() } }
                    Button(searching ? "Looking up…" : "Look up") { Task { await lookUp() } }
                        .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || searching)
                }
                if let status {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Units") {
                Picker("Temperature", selection: $state.config.fahrenheit) {
                    Text("°F").tag(true)
                    Text("°C").tag(false)
                }
                .pickerStyle(.segmented)
            }
            Section {
                Text("Forecasts come from Open-Meteo. No account or API key needed. Click the weather on the dock to open the Weather app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @MainActor
    private func lookUp() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searching = true
        defer { searching = false }

        var comps = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        comps.queryItems = [URLQueryItem(name: "name", value: q), URLQueryItem(name: "count", value: "1")]
        guard let url = comps.url else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let r = try JSONDecoder().decode(GeoResponse.self, from: data)
            guard let place = r.results?.first else {
                status = "No place called “\(q)” found."
                return
            }
            state.config.cityName = place.name
            state.config.latitude = place.latitude
            state.config.longitude = place.longitude
            let region = [place.admin1, place.country_code].compactMap { $0 }.joined(separator: ", ")
            status = "Set to \(place.name)\(region.isEmpty ? "" : ", \(region)")."
            query = ""
        } catch {
            status = "Couldn't reach the location service."
        }
    }
}

// MARK: - Notch

struct NotchSettings: View {
    @EnvironmentObject var state: AppState

    private var hasNotch: Bool { NSScreen.screens.contains { $0.safeAreaInsets.top > 0 } }

    var body: some View {
        Form {
            Section {
                Toggle("Use the notch", isOn: $state.config.notchEnabled)
                if !hasNotch {
                    Toggle("Add a notch on Macs that don't have one", isOn: $state.config.notchFakeOnOtherMacs)
                }
                Toggle("Show it as a floating Dynamic Island on displays without a notch", isOn: $state.config.notchIsland)
                Text(hasNotch
                     ? "Hover the notch to open it: music, your calendar, a file shelf and a mirror."
                     : "This Mac has no notch. Turn on the option above to get one at the top of the main display.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Opening") {
                Picker("Open the notch by", selection: $state.config.notchOpenOnHover) {
                    Text("Hovering").tag(true)
                    Text("Clicking").tag(false)
                }
                .pickerStyle(.segmented)
                if state.config.notchOpenOnHover {
                    LabeledSlider(title: "Hover delay", value: $state.config.notchHoverDelay, range: 0...1, format: "%.2fs")
                }
                Toggle("In browsers (Chrome, Safari, Arc…), open only by clicking", isOn: $state.config.notchClickInBrowsers)
                Text("Hovering opens the notch only when the pointer rests on the notch itself. Clicking and dragging tabs near it won't open it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Open to the shelf when dragging files toward it", isOn: $state.config.notchOpenOnDrag)
                Toggle("Haptic feedback when it opens", isOn: $state.config.notchHaptics)
            }
            .disabled(!state.config.notchEnabled)

            Section("Look") {
                Picker("Finish when open", selection: $state.config.notchFinish) {
                    Text("Black").tag("black")
                    Text("Glass").tag("glass")
                }
                .pickerStyle(.segmented)
                Text("Closed, the notch is always black so it matches the real one. The highlight color is your accent color (Settings → General).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!state.config.notchEnabled)

            Section("System overlays") {
                Toggle("Replace the macOS volume and brightness overlays with the notch", isOn: $state.config.replaceSystemHUD)
                Text("Driftdock handles the volume, mute and brightness keys itself, so only the notch shows the change (Shift+Option for finer steps). Needs Accessibility. macOS's own AirPods \"Connected\" popup can't be turned off by apps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!state.config.notchEnabled)

            Section("Tabs") {
                Toggle("When nothing is playing, open to Today instead of the player", isOn: $state.config.notchTodayWhenIdle)
                NotchTabsEditor()
            }
            .disabled(!state.config.notchEnabled)

            Section("Live activities (while closed)") {
                Toggle("Timers and stopwatches", isOn: $state.config.notchLiveTimers)
                Toggle("Calls (FaceTime, Zoom, Teams, Meet, Discord…) with a mic mute button", isOn: $state.config.notchLiveCalls)
                Toggle("Album art and a visualizer while music plays", isOn: $state.config.notchLiveMusic)
                Toggle("Visualizer moves with the music (bass on the left, treble on the right)", isOn: $state.config.reactiveVisualizer)
                Text("Listens only to Music or Spotify, only while the visualizer is showing. macOS asks for Screen & System Audio Recording the first time; until then the bars use a gentle animation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Focus timer countdown", isOn: $state.config.notchLiveFocus)
                Toggle("Files waiting in the shelf", isOn: $state.config.notchLiveShelf)
                Toggle("Banners for Full Battery, devices connecting and focus sessions ending", isOn: $state.config.notchBanners)
                Toggle("Volume changes", isOn: $state.config.notchVolumeHUD)
                Toggle("Downloads in progress, with a check when they finish", isOn: $state.config.notchDownloads)
                Toggle("Battery while charging", isOn: $state.config.notchLiveBattery)
            }
            .disabled(!state.config.notchEnabled)

            Section("When open") {
                Toggle("Calendar (next events)", isOn: $state.config.notchCalendar)
                Toggle("File shelf (with convert, compress, OCR, PDF, zip and more)", isOn: $state.config.notchShelf)
                Toggle("Tools (Stay Awake, focus timer, color picker, launcher…)", isOn: $state.config.notchTools)
                Toggle("Mirror (camera preview)", isOn: $state.config.notchMirror)
                Text("Now playing and battery are always on the Home tab. Calendar and Mirror ask for permission the first time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!state.config.notchEnabled)
        }
        .formStyle(.grouped)
    }
}

// MARK: - Extras

struct ExtrasSettings: View {
    @EnvironmentObject var state: AppState
    @State private var trusted = Paster.isTrusted

    var body: some View {
        Form {
            Section("Launcher") {
                Toggle("⌥Space opens the launcher", isOn: $state.config.launcherHotkey)
                Text("Search apps, run commands (Stay Awake, pick a color, dark mode…), do quick math like (24+18)*3, or search the web. Return copies a math result.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Voice Transcribe") {
                Toggle("⌥⇧D starts and stops live dictation in the notch", isOn: $state.config.dictationHotkey)
                Text("Your words stream into the notch as you speak; when you stop, the transcript is copied. Runs on this Mac when your Mac supports it. Asks for Microphone and Speech Recognition the first time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Clipboard") {
                Toggle("⇧⌘V opens the Clipboard Manager (text and images, pin, rename, copy text from images, drag out)", isOn: $state.config.clipboardHotkey)
                Toggle("Paste right away after choosing", isOn: $state.config.clipboardAutoPaste)
                    .onChange(of: state.config.clipboardAutoPaste) { _, on in
                        if on && !Paster.isTrusted { Paster.requestAccess() }
                    }
                if state.config.clipboardAutoPaste && !trusted {
                    HStack {
                        Text("Pasting needs Accessibility access for Driftdock.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Check again") { trusted = Paster.isTrusted }.controlSize(.small)
                    }
                }
            }
            Section("Window snapping") {
                Toggle("Keyboard shortcuts (⌃⌥ + arrows and more)", isOn: $state.config.snapHotkeys)
                Toggle("Drag a window to a screen edge or corner to snap it", isOn: $state.config.snapDrag)
                LabeledSlider(title: "Gap between windows", value: $state.config.snapGap, range: 0...24, format: "%.0f pt")
                Toggle("Leave room for Driftdock when it isn't auto-hiding", isOn: $state.config.snapAvoidDock)
                if !trusted {
                    HStack {
                        Text("Snapping needs Accessibility access for Driftdock.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Settings") { Paster.openSettings() }.controlSize(.small)
                        Button("Check again") { trusted = Paster.isTrusted }.controlSize(.small)
                    }
                }
                DisclosureGroup("Shortcuts") {
                    ForEach(SnapTarget.allCases, id: \.self) { t in
                        LabeledContent(t.title, value: ExtrasController.snapKeyNames[t] ?? "")
                    }
                    LabeledContent("Undo last snap", value: "⌃⌥⌫")
                }
            }

            Section("AirPods & devices") {
                Toggle("Show battery for AirPods and other Bluetooth devices", isOn: $state.config.devicesBattery)
                Text("Left, right and case for AirPods; one level for keyboards, mice and headphones. Shows in the dock (AirPods & Devices widget), the notch, and a quick note when something connects.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Per-app volume (beta)") {
                Toggle("Set a separate volume for each app", isOn: $state.config.perAppVolume)
                Toggle("Volume Mixer tab in the notch", isOn: $state.config.notchMixer)
                    .disabled(!state.config.perAppVolume)
                Text(MixerModel.isSupported
                     ? "0–200% per app from the notch's mixer tab or the menu bar. An app left at 100% isn't touched. The first change asks for System Audio Recording permission."
                     : "Needs macOS 14.2 or later.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !state.config.appVolumes.isEmpty {
                    Button("Reset all apps to 100%") {
                        for id in state.config.appVolumes.keys { MixerModel.shared.setGain(1, for: id) }
                    }
                    .controlSize(.small)
                }
            }

            Section("File Tray") {
                Toggle("Shake a file while dragging it to open the File Tray", isOn: $state.config.shakeForTray)
                Text("Drop files in the tray to hold them, then drag them out wherever you need them. The tray shares its files with the notch shelf, and its Actions menu converts, compresses, cuts out backgrounds, copies text, makes GIFs and PDFs, zips and shares.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { trusted = Paster.isTrusted }
    }
}

// MARK: - Clock

struct ClockSettings: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Form {
            Section {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    HStack {
                        Spacer()
                        ClockWidget()
                            .environment(\.dockUnit, 72)
                            .environment(\.colorScheme, .dark)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.black.opacity(0.85)))
                        Spacer()
                    }
                }
            } header: {
                Text("Preview")
            }

            Section("Style") {
                Picker("Clock", selection: $state.config.clockStyle) {
                    Text("Digital").tag("digital")
                    Text("Analog").tag("analog")
                    Text("Both").tag("both")
                }
                .pickerStyle(.segmented)
                Toggle("24-hour time", isOn: $state.config.clock24h)
                Toggle("Show seconds", isOn: $state.config.clockSeconds)
                Toggle("Seconds hand in the accent color", isOn: $state.config.clockAccentSeconds)
                    .disabled(state.config.clockStyle == "digital")
            }

            Section("Color") {
                Picker("Clock color", selection: $state.config.clockColor) {
                    ForEach(ClockFormat.colors, id: \.id) { c in Text(c.name).tag(c.id) }
                }
            }

            Section("Font") {
                Picker("Typeface", selection: $state.config.clockFont) {
                    Text("Rounded").tag("rounded")
                    Text("Standard").tag("default")
                    Text("Serif").tag("serif")
                    Text("Mono").tag("mono")
                }
                .pickerStyle(.segmented)
                Picker("Weight", selection: $state.config.clockWeight) {
                    Text("Light").tag("light")
                    Text("Regular").tag("regular")
                    Text("Semibold").tag("semibold")
                    Text("Bold").tag("bold")
                    Text("Heavy").tag("heavy")
                }
                .pickerStyle(.segmented)
            }
            .disabled(state.config.clockStyle == "analog")

            Section("Date") {
                Toggle("Show the date", isOn: $state.config.clockShowDate)
                Picker("Date format", selection: $state.config.clockDateStyle) {
                    Text("Tue, Oct 20").tag("weekday")
                    Text("Tuesday, October 20").tag("full")
                    Text("10/20/26").tag("numeric")
                    Text("Tuesday").tag("day")
                }
                .disabled(!state.config.clockShowDate)
            }
            .disabled(state.config.clockStyle == "analog")

            Section("World clock") {
                Picker("Second time zone", selection: $state.config.clockSecondZone) {
                    Text("None").tag("")
                    Divider()
                    ForEach(ClockFormat.zones, id: \.id) { zone in
                        Text(zone.label).tag(zone.id)
                    }
                }
                Toggle("Show the time in the open notch", isOn: $state.config.clockInNotch)
            }
        }
        .formStyle(.grouped)
    }
}

/// Reorder, add and remove the notch's tabs.
struct NotchTabsEditor: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        let tabs = NotchModel.tabs(state.config)
        let missing = NotchModel.Tab.allCases.filter { !tabs.contains($0) && ($0 != .mixer || MixerModel.isSupported) }
        VStack(alignment: .leading, spacing: 6) {
            List {
                ForEach(tabs, id: \.self) { tab in
                    HStack(spacing: 10) {
                        Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                        Image(systemName: NotchModel.icon(tab)).frame(width: 20).foregroundStyle(state.accent)
                        Text(NotchModel.title(tab))
                        Spacer()
                        Button {
                            NotchModel.removeTab(tab)
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                        .disabled(tabs.count <= 1)
                        .help("Remove this tab")
                    }
                }
                .onMove { from, to in
                    var t = tabs
                    t.move(fromOffsets: from, toOffset: to)
                    NotchModel.setTabs(t)
                }
            }
            .frame(height: CGFloat(tabs.count) * 28 + 12)
            .listStyle(.inset(alternatesRowBackgrounds: true))
            HStack {
                Menu("Add Tab") {
                    ForEach(missing, id: \.self) { t in
                        Button { NotchModel.addTab(t) } label: { Label(NotchModel.title(t), systemImage: NotchModel.icon(t)) }
                    }
                }
                .disabled(missing.isEmpty)
                .fixedSize()
                Spacer()
                Button("Reset") { state.config.notchTabs = [] }
            }
            Text("Drag rows to reorder. In the notch you can also drag tabs onto each other, right-click a tab, or use the + at the end of the tab bar.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
