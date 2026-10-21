import SwiftUI
import AppKit

// MARK: - Settings enums

enum DockEdge: String, Codable, CaseIterable, Identifiable {
    case bottom, top, left, right
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var isHorizontal: Bool { self == .bottom || self == .top }

    /// Edge of the anchor the popover arrow sits on, so popovers open away from the screen edge.
    var popoverArrow: Edge {
        switch self {
        case .bottom: return .top
        case .top: return .bottom
        case .left: return .trailing
        case .right: return .leading
        }
    }
}

enum DockAlign: String, Codable, CaseIterable, Identifiable {
    case leading, center, trailing
    var id: String { rawValue }
    var title: String {
        switch self {
        case .leading: return "Start"
        case .center: return "Center"
        case .trailing: return "End"
        }
    }
}

enum Backdrop: String, Codable, CaseIterable, Identifiable {
    case glass, dark, light, tinted
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum WidgetKind: String, Codable, CaseIterable, Identifiable {
    case clock, weather, apps, screenshots, devices, nowPlaying, stats, todos, pomodoro, clipboard, search, toggles
    var id: String { rawValue }

    var title: String {
        switch self {
        case .clock: return "Clock"
        case .weather: return "Weather"
        case .apps: return "Apps & Folders"
        case .screenshots: return "Recent Screenshots"
        case .devices: return "AirPods & Devices"
        case .nowPlaying: return "Now Playing"
        case .stats: return "System Stats"
        case .todos: return "To-dos"
        case .pomodoro: return "Focus Timer"
        case .clipboard: return "Clipboard"
        case .search: return "Search"
        case .toggles: return "Quick Toggles"
        }
    }

    var symbol: String {
        switch self {
        case .clock: return "clock"
        case .weather: return "cloud.sun"
        case .apps: return "square.grid.2x2"
        case .screenshots: return "camera.viewfinder"
        case .devices: return "airpods"
        case .nowPlaying: return "music.note"
        case .stats: return "gauge.with.dots.needle.33percent"
        case .todos: return "checklist"
        case .pomodoro: return "timer"
        case .clipboard: return "doc.on.clipboard"
        case .search: return "magnifyingglass"
        case .toggles: return "switch.2"
        }
    }
}

struct WidgetEntry: Codable, Identifiable, Hashable {
    var kind: WidgetKind
    var enabled: Bool
    var id: WidgetKind { kind }
}

struct PinnedItem: Codable, Identifiable, Hashable {
    var id = UUID()
    var path: String
}

// MARK: - Config

struct Config: Codable {
    var edge: DockEdge = .bottom
    var display = "main"                 // see DisplayChoice: main, follow, all, screen:<name>
    var align: DockAlign = .center
    var margin: Double = 3
    var scale: Double = 1.0
    var autoHide = false
    var replaceSystemDock = false
    var backdrop: Backdrop = .glass
    var accentHex = "#FF7A45"
    var useSystemAccent = true
    var cornerRadius: Double = 22
    var widgets: [WidgetEntry] = WidgetKind.allCases.map {
        WidgetEntry(kind: $0, enabled: [.clock, .weather, .apps, .screenshots, .devices, .nowPlaying, .stats, .todos].contains($0))
    }
    var pinned: [PinnedItem] = Config.defaultPinned
    var showOpenApps = true
    var showAppDivider = true
    var showRunningDots = true
    var dimHiddenApps = true
    var clickActiveToHide = false
    var openAppsSort = "launch"          // "launch" or "name"
    var useCurrentLocation = true
    var screenshotMinutes: Double = 3
    var includeRecordings = true
    var revealOnScreenshot = true
    var notchEnabled = true
    var notchFakeOnOtherMacs = false
    var notchOpenOnHover = true
    var notchHoverDelay: Double = 0.35
    var notchLiveMusic = true
    var notchLiveBattery = true
    var notchOpenOnDrag = true
    var notchCalendar = true
    var notchShelf = true
    var notchMirror = true
    var notchHaptics = true
    var notchClickInBrowsers = false
    var launcherHotkey = true
    var clipboardHotkey = true
    var clipboardAutoPaste = false
    var shakeForTray = true
    var notchVolumeHUD = true
    var notchDownloads = true
    var notchFinish = "black"
    var notchTools = true
    var devicesBattery = true
    var snapHotkeys = true
    var snapDrag = true
    var snapGap: Double = 0
    var snapAvoidDock = true
    var perAppVolume = true
    var appVolumes: [String: Double] = [:]
    var notchMixer = true
    var clockStyle = "digital"
    var idleMusicApp = "com.apple.Music"
    var hideIdleMusic = true
    var statsShowTemp = true
    var reactiveVisualizer = true
    var eqEnabled = false
    var notchTabs: [String] = []
    var notchLiveTimers = true
    var notchTodayWhenIdle = true
    var notchLiveCalls = true
    var eqBands: [Double] = Array(repeating: 0, count: 10)
    var eqPreamp: Double = 0
    var eqAutoPreamp = true
    var eqPresetName = "Flat"
    var eqCustomPresets: [String: [Double]] = [:]
    var audioBoost: Double = 0
    var audioBalance: Double = 0
    var replaceSystemHUD = true
    var showTrash = true
    var clockColor = "default"
    var dictationHotkey = true
    var notchLiveFocus = true
    var notchLiveShelf = true
    var notchBanners = true
    var notchIsland = true
    var clock24h = false
    var clockSeconds = false
    var clockShowDate = true
    var clockDateStyle = "weekday"
    var clockFont = "rounded"
    var clockWeight = "semibold"
    var clockSecondZone = ""
    var clockAccentSeconds = true
    var clockInNotch = false
    var cityName = "Boston"
    var latitude = 42.3601
    var longitude = -71.0589
    var fahrenheit = true
    var searchEngine = "google"
    var glideEnabled = false
    var glideRole = "receive"            // "receive" (other computer has the mouse) or "share"
    var glideHost = ""
    var glideEdge = "right"
    var glideSpeed: Double = 1.0
    var glideFlashes = true

    static var defaultPinned: [PinnedItem] {
        [
            "/System/Library/CoreServices/Finder.app",
            "/Applications/Safari.app",
            "/System/Applications/Music.app",
            "/System/Applications/Notes.app",
            "/System/Applications/System Settings.app",
            NSHomeDirectory() + "/Downloads",
        ]
        .filter { FileManager.default.fileExists(atPath: $0) }
        .map { PinnedItem(path: $0) }
    }

    init() {}

    enum CodingKeys: String, CodingKey {
        case edge, display, align, margin, scale, autoHide, replaceSystemDock, backdrop, accentHex, useSystemAccent, cornerRadius
        case widgets, pinned, showOpenApps, showAppDivider, showRunningDots, dimHiddenApps
        case clickActiveToHide, openAppsSort, useCurrentLocation
        case notchTabs, notchTodayWhenIdle, notchLiveTimers, notchLiveCalls, eqEnabled, eqBands, eqPreamp, eqAutoPreamp, eqPresetName, eqCustomPresets, audioBoost, audioBalance
        case reactiveVisualizer, statsShowTemp, replaceSystemHUD, dictationHotkey, idleMusicApp, hideIdleMusic, showTrash, clockColor, notchLiveFocus, notchLiveShelf, notchBanners, notchIsland
        case clockStyle, clock24h, clockSeconds, clockShowDate, clockDateStyle, clockFont, clockWeight, clockSecondZone, clockAccentSeconds, clockInNotch
        case devicesBattery, snapHotkeys, snapDrag, snapGap, snapAvoidDock, perAppVolume, appVolumes, notchMixer
        case launcherHotkey, clipboardHotkey, clipboardAutoPaste, shakeForTray, notchVolumeHUD, notchDownloads, notchFinish, notchTools
        case notchClickInBrowsers, notchEnabled, notchFakeOnOtherMacs, notchOpenOnHover, notchHoverDelay, notchLiveMusic, notchLiveBattery, notchOpenOnDrag, notchCalendar, notchShelf, notchMirror, notchHaptics
        case screenshotMinutes, includeRecordings, revealOnScreenshot, cityName, latitude, longitude, fahrenheit, searchEngine
        case glideEnabled, glideRole, glideHost, glideEdge, glideSpeed, glideFlashes
    }

    // Tolerant decoding: missing or new keys fall back to defaults instead of wiping settings.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        edge = c.value(.edge, d.edge)
        display = c.value(.display, d.display)
        align = c.value(.align, d.align)
        margin = c.value(.margin, d.margin)
        scale = c.value(.scale, d.scale)
        autoHide = c.value(.autoHide, d.autoHide)
        replaceSystemDock = c.value(.replaceSystemDock, d.replaceSystemDock)
        backdrop = c.value(.backdrop, d.backdrop)
        accentHex = c.value(.accentHex, d.accentHex)
        useSystemAccent = c.value(.useSystemAccent, d.useSystemAccent)
        cornerRadius = c.value(.cornerRadius, d.cornerRadius)
        widgets = c.value(.widgets, d.widgets)
        pinned = c.value(.pinned, d.pinned)
        showOpenApps = c.value(.showOpenApps, d.showOpenApps)
        showAppDivider = c.value(.showAppDivider, d.showAppDivider)
        showRunningDots = c.value(.showRunningDots, d.showRunningDots)
        dimHiddenApps = c.value(.dimHiddenApps, d.dimHiddenApps)
        clickActiveToHide = c.value(.clickActiveToHide, d.clickActiveToHide)
        openAppsSort = c.value(.openAppsSort, d.openAppsSort)
        useCurrentLocation = c.value(.useCurrentLocation, d.useCurrentLocation)
        screenshotMinutes = c.value(.screenshotMinutes, d.screenshotMinutes)
        includeRecordings = c.value(.includeRecordings, d.includeRecordings)
        revealOnScreenshot = c.value(.revealOnScreenshot, d.revealOnScreenshot)
        notchEnabled = c.value(.notchEnabled, d.notchEnabled)
        notchFakeOnOtherMacs = c.value(.notchFakeOnOtherMacs, d.notchFakeOnOtherMacs)
        notchOpenOnHover = c.value(.notchOpenOnHover, d.notchOpenOnHover)
        notchHoverDelay = c.value(.notchHoverDelay, d.notchHoverDelay)
        notchLiveMusic = c.value(.notchLiveMusic, d.notchLiveMusic)
        notchLiveBattery = c.value(.notchLiveBattery, d.notchLiveBattery)
        notchOpenOnDrag = c.value(.notchOpenOnDrag, d.notchOpenOnDrag)
        notchCalendar = c.value(.notchCalendar, d.notchCalendar)
        notchShelf = c.value(.notchShelf, d.notchShelf)
        notchMirror = c.value(.notchMirror, d.notchMirror)
        notchHaptics = c.value(.notchHaptics, d.notchHaptics)
        notchClickInBrowsers = c.value(.notchClickInBrowsers, d.notchClickInBrowsers)
        launcherHotkey = c.value(.launcherHotkey, d.launcherHotkey)
        clipboardHotkey = c.value(.clipboardHotkey, d.clipboardHotkey)
        clipboardAutoPaste = c.value(.clipboardAutoPaste, d.clipboardAutoPaste)
        shakeForTray = c.value(.shakeForTray, d.shakeForTray)
        notchVolumeHUD = c.value(.notchVolumeHUD, d.notchVolumeHUD)
        notchDownloads = c.value(.notchDownloads, d.notchDownloads)
        notchFinish = c.value(.notchFinish, d.notchFinish)
        notchTools = c.value(.notchTools, d.notchTools)
        devicesBattery = c.value(.devicesBattery, d.devicesBattery)
        snapHotkeys = c.value(.snapHotkeys, d.snapHotkeys)
        snapDrag = c.value(.snapDrag, d.snapDrag)
        snapGap = c.value(.snapGap, d.snapGap)
        snapAvoidDock = c.value(.snapAvoidDock, d.snapAvoidDock)
        perAppVolume = c.value(.perAppVolume, d.perAppVolume)
        appVolumes = c.value(.appVolumes, d.appVolumes)
        notchMixer = c.value(.notchMixer, d.notchMixer)
        clockStyle = c.value(.clockStyle, d.clockStyle)
        idleMusicApp = c.value(.idleMusicApp, d.idleMusicApp)
        hideIdleMusic = c.value(.hideIdleMusic, d.hideIdleMusic)
        statsShowTemp = c.value(.statsShowTemp, d.statsShowTemp)
        reactiveVisualizer = c.value(.reactiveVisualizer, d.reactiveVisualizer)
        eqEnabled = c.value(.eqEnabled, d.eqEnabled)
        notchTabs = c.value(.notchTabs, d.notchTabs)
        notchLiveTimers = c.value(.notchLiveTimers, d.notchLiveTimers)
        notchTodayWhenIdle = c.value(.notchTodayWhenIdle, d.notchTodayWhenIdle)
        notchLiveCalls = c.value(.notchLiveCalls, d.notchLiveCalls)
        eqBands = c.value(.eqBands, d.eqBands)
        eqPreamp = c.value(.eqPreamp, d.eqPreamp)
        eqAutoPreamp = c.value(.eqAutoPreamp, d.eqAutoPreamp)
        eqPresetName = c.value(.eqPresetName, d.eqPresetName)
        eqCustomPresets = c.value(.eqCustomPresets, d.eqCustomPresets)
        audioBoost = c.value(.audioBoost, d.audioBoost)
        audioBalance = c.value(.audioBalance, d.audioBalance)
        replaceSystemHUD = c.value(.replaceSystemHUD, d.replaceSystemHUD)
        showTrash = c.value(.showTrash, d.showTrash)
        clockColor = c.value(.clockColor, d.clockColor)
        dictationHotkey = c.value(.dictationHotkey, d.dictationHotkey)
        notchLiveFocus = c.value(.notchLiveFocus, d.notchLiveFocus)
        notchLiveShelf = c.value(.notchLiveShelf, d.notchLiveShelf)
        notchBanners = c.value(.notchBanners, d.notchBanners)
        notchIsland = c.value(.notchIsland, d.notchIsland)
        clock24h = c.value(.clock24h, d.clock24h)
        clockSeconds = c.value(.clockSeconds, d.clockSeconds)
        clockShowDate = c.value(.clockShowDate, d.clockShowDate)
        clockDateStyle = c.value(.clockDateStyle, d.clockDateStyle)
        clockFont = c.value(.clockFont, d.clockFont)
        clockWeight = c.value(.clockWeight, d.clockWeight)
        clockSecondZone = c.value(.clockSecondZone, d.clockSecondZone)
        clockAccentSeconds = c.value(.clockAccentSeconds, d.clockAccentSeconds)
        clockInNotch = c.value(.clockInNotch, d.clockInNotch)
        cityName = c.value(.cityName, d.cityName)
        latitude = c.value(.latitude, d.latitude)
        longitude = c.value(.longitude, d.longitude)
        fahrenheit = c.value(.fahrenheit, d.fahrenheit)
        searchEngine = c.value(.searchEngine, d.searchEngine)
        glideEnabled = c.value(.glideEnabled, d.glideEnabled)
        glideRole = c.value(.glideRole, d.glideRole)
        glideHost = c.value(.glideHost, d.glideHost)
        glideEdge = c.value(.glideEdge, d.glideEdge)
        glideSpeed = c.value(.glideSpeed, d.glideSpeed)
        glideFlashes = c.value(.glideFlashes, d.glideFlashes)
    }
}

private extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
    }
}

// MARK: - App state

final class AppState: ObservableObject {
    static let shared = AppState()
    private static let storageKey = "driftdock.config.v1"

    @Published var config: Config {
        didSet { save() }
    }

    /// Extra shrink applied automatically so the dock never runs off the screen (not saved).
    @Published var fitScale: CGFloat = 1

    /// True while widgets wiggle and can be dragged into a new order on the dock.
    @Published var arranging = false

    /// Turns a widget on or off (it keeps its place in the order).
    func setWidget(_ kind: WidgetKind, enabled: Bool) {
        guard let i = config.widgets.firstIndex(where: { $0.kind == kind }) else { return }
        config.widgets[i].enabled = enabled
        if enabled { LiveActivityCenter.shared.flash(symbol: kind.symbol, text: "\(kind.title) added") }
    }

    /// Moves a widget to where `target` is, shifting the others along.
    func moveWidget(_ kind: WidgetKind, to target: WidgetKind) {
        guard kind != target,
              let from = config.widgets.firstIndex(where: { $0.kind == kind }),
              let to = config.widgets.firstIndex(where: { $0.kind == target }) else { return }
        var list = config.widgets
        let entry = list.remove(at: from)
        let insertAt = list.firstIndex(where: { $0.kind == target }).map { from < to ? $0 + 1 : $0 } ?? list.count
        list.insert(entry, at: insertAt)
        config.widgets = list
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           var saved = try? JSONDecoder().decode(Config.self, from: data) {
            // Add any widget kinds introduced after the settings were saved.
            // Recent Screenshots is on for upgrades too; it only shows when there's something to show.
            let onForUpgrades: Set<WidgetKind> = [.screenshots, .devices]
            for kind in WidgetKind.allCases where !saved.widgets.contains(where: { $0.kind == kind }) {
                let entry = WidgetEntry(kind: kind, enabled: onForUpgrades.contains(kind))
                if kind == .screenshots || kind == .devices,
                   let apps = saved.widgets.firstIndex(where: { $0.kind == .apps }) {
                    saved.widgets.insert(entry, at: apps + 1)   // right after your apps
                } else {
                    saved.widgets.append(entry)
                }
            }
            // The old 0.15s hover delay was too eager (browser tabs sit under the notch).
            if abs(saved.notchHoverDelay - 0.15) < 0.001 { saved.notchHoverDelay = 0.35 }
            config = saved
        } else {
            config = Config()
        }
        // Repaint when the system accent color changes in System Settings → Appearance.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleColorPreferencesChangedNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in self?.objectWillChange.send() }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    var accent: Color {
        config.useSystemAccent ? Color(nsColor: .controlAccentColor) : Color(hex: config.accentHex)
    }

    func addPinned(_ urls: [URL]) {
        for url in urls where url.isFileURL {
            let path = url.standardizedFileURL.path
            if !config.pinned.contains(where: { $0.path == path }) {
                config.pinned.append(PinnedItem(path: path))
            }
        }
    }
}

// MARK: - Color helpers

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r = Double((v >> 16) & 0xFF) / 255
        let g = Double((v >> 8) & 0xFF) / 255
        let b = Double(v & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }

    var hexString: String {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return "#FF7A45" }
        let r = Int((c.redComponent * 255).rounded())
        let g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
