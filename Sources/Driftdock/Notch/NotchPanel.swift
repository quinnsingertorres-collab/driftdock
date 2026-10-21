import AppKit
import SwiftUI
import Combine

// MARK: - Geometry

enum NotchGeometry {
    /// The built-in display with a camera notch, or (if allowed) the main display.
    static func screen(allowFake: Bool) -> NSScreen? {
        if let notched = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) { return notched }
        return allowFake ? NSScreen.screens.first : nil
    }

    /// Size of the hardware notch, or a menu-bar-height pill on Macs without one.
    static func notchSize(on screen: NSScreen) -> CGSize {
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            return CGSize(width: screen.frame.width - left.width - right.width,
                          height: screen.safeAreaInsets.top)
        }
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        return CGSize(width: 190, height: max(24, min(menuBar, 37)))
    }
}

// MARK: - Model

final class NotchModel: ObservableObject {
    enum Tab: String, CaseIterable { case home, shelf, calendar, timers, tools, mixer, mirror }

    @Published var expanded = false
    @Published var tab: Tab = .home
    @Published var notchSize = CGSize(width: 190, height: 32)
    /// True on displays without a camera notch: draw a floating Dynamic Island instead.
    @Published var isIsland = false

    /// Size of the open panel, not counting the shadow margin.
    static let openWidth: CGFloat = 460
    static let openBodyHeight: CGFloat = 152
    static let shadowMargin: CGFloat = 24
    /// The floating tab bar under the open notch.
    static let pillHeight: CGFloat = 36
    static let pillGap: CGFloat = 8
    /// Extra height a two-line banner adds below the closed notch.
    static let bannerHeight: CGFloat = 50
    /// Gap above the island on displays without a notch.
    static let islandInset: CGFloat = 6

    /// The tab bar, in the person's order. Before they customize it, it follows the old on/off switches.
    static func tabs(_ cfg: Config) -> [Tab] {
        let order: [Tab]
        if cfg.notchTabs.isEmpty {
            order = Tab.allCases.filter {
                switch $0 {
                case .home, .timers: return true
                case .shelf: return cfg.notchShelf
                case .calendar: return cfg.notchCalendar
                case .tools: return cfg.notchTools
                case .mixer: return cfg.notchMixer
                case .mirror: return cfg.notchMirror
                }
            }
        } else {
            order = cfg.notchTabs.compactMap(Tab.init(rawValue:))
        }
        let usable = order.filter { $0 != .mixer || MixerModel.isSupported }
        return usable.isEmpty ? [.home] : usable
    }

    static func setTabs(_ tabs: [Tab]) {
        var seen = Set<Tab>()
        let clean = tabs.filter { seen.insert($0).inserted }
        AppState.shared.config.notchTabs = (clean.isEmpty ? [.home] : clean).map(\.rawValue)
    }

    static func addTab(_ tab: Tab) {
        let cur = tabs(AppState.shared.config)
        guard !cur.contains(tab) else { return }
        setTabs(cur + [tab])
    }

    static func removeTab(_ tab: Tab) {
        setTabs(tabs(AppState.shared.config).filter { $0 != tab })
    }

    /// Moves `tab` to where `target` is.
    static func moveTab(_ tab: Tab, to target: Tab) {
        var cur = tabs(AppState.shared.config)
        guard tab != target, let from = cur.firstIndex(of: tab), let to = cur.firstIndex(of: target) else { return }
        cur.remove(at: from)
        cur.insert(tab, at: to)
        setTabs(cur)
    }

    static func shiftTab(_ tab: Tab, by delta: Int) {
        var cur = tabs(AppState.shared.config)
        guard let i = cur.firstIndex(of: tab) else { return }
        let j = max(0, min(cur.count - 1, i + delta))
        guard i != j else { return }
        cur.remove(at: i)
        cur.insert(tab, at: j)
        setTabs(cur)
    }

    static func icon(_ tab: Tab) -> String {
        switch tab {
        case .home: return "house.fill"
        case .shelf: return "tray.fill"
        case .calendar: return "calendar"
        case .tools: return "square.grid.2x2.fill"
        case .timers: return "timer"
        case .mixer: return "slider.horizontal.3"
        case .mirror: return "person.crop.circle"
        }
    }

    static func title(_ tab: Tab) -> String {
        switch tab {
        case .home: return "Now Playing"
        case .shelf: return "File Tray"
        case .calendar: return "Today"
        case .tools: return "Tools"
        case .timers: return "Timers"
        case .mixer: return "Volume Mixer"
        case .mirror: return "Mirror"
        }
    }
}

/// Files held in the notch shelf for this session.
final class ShelfModel: ObservableObject {
    static let shared = ShelfModel()
    @Published var items: [URL] = []
    /// Files picked for the next action (click to select). Empty means "all".
    @Published var selection = Set<URL>()
    /// What's running right now, e.g. "Compressing…".
    @Published var busy: String?

    func add(_ urls: [URL]) {
        for url in urls where url.isFileURL && !items.contains(url) { items.append(url) }
    }
    func remove(_ url: URL) {
        items.removeAll { $0 == url }
        selection.remove(url)
    }
    func toggleSelection(_ url: URL) {
        if selection.contains(url) { selection.remove(url) } else { selection.insert(url) }
    }
}

// MARK: - Panel

/// A transparent window over the notch. It ignores the mouse while collapsed
/// (so the menu bar keeps working) and watches the pointer to know when to open.
final class NotchPanel: NSPanel {
    let model = NotchModel()
    private let state: AppState
    private var screenID: CGDirectDisplayID
    private var timer: Timer?
    private var hoverStart: Date?
    private var hoverAnchor: NSPoint?
    private var wasPressed = false
    private var lastPressEnd = Date.distantPast
    private var dragCountAtPress = 0

    /// Browsers, where the tab strip sits right under the notch.
    private static let browsers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary", "com.apple.Safari",
        "company.thebrowser.Browser", "com.microsoft.edgemac", "org.mozilla.firefox",
        "com.brave.Browser", "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
    ]
    private var lastInside = Date()
    private var cancellables = Set<AnyCancellable>()

    init(state: AppState, screen: NSScreen) {
        self.state = state
        self.screenID = screen.displayID
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        // Above the menu bar so the notch can draw over it.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        ignoresMouseEvents = true

        let root = NotchRootView()
            .environmentObject(model)
            .environmentObject(state)
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        contentView = host

        layoutOnScreen()

        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    var currentScreen: NSScreen? {
        NSScreen.screens.first { $0.displayID == screenID }
    }

    func teardown() {
        NotchSpace.shared.remove(self)
        timer?.invalidate()
        timer = nil
        cancellables.removeAll()
        orderOut(nil)
    }

    func layoutOnScreen() {
        guard let screen = currentScreen else { return }
        model.notchSize = NotchGeometry.notchSize(on: screen)
        model.isIsland = screen.safeAreaInsets.top == 0 && state.config.notchIsland
        let w = NotchModel.openWidth + NotchModel.shadowMargin * 2
        let h = model.notchSize.height + NotchModel.openBodyHeight + NotchModel.pillGap
            + NotchModel.pillHeight + NotchModel.shadowMargin + NotchModel.islandInset
        let frame = NSRect(x: screen.frame.midX - w / 2, y: screen.frame.maxY - h, width: w, height: h)
        setFrame(frame.integral, display: true)
        orderFrontRegardless()
        // Stay visible while swiping between Spaces / full-screen apps.
        NotchSpace.shared.add(self)
    }

    // MARK: Pointer tracking

    /// The collapsed notch in screen coordinates (including any live-activity wings).
    private var collapsedRect: NSRect {
        guard let screen = currentScreen else { return .zero }
        let size = model.notchSize
        let wings = size.height * 2.4
        let w = size.width + wings
        let inset = model.isIsland ? NotchModel.islandInset : 0
        return NSRect(x: screen.frame.midX - w / 2, y: screen.frame.maxY - size.height - inset, width: w, height: size.height + inset)
    }

    private var openRect: NSRect {
        guard let screen = currentScreen else { return .zero }
        let w = NotchModel.openWidth
        let h = model.notchSize.height + NotchModel.openBodyHeight + NotchModel.pillGap + NotchModel.pillHeight
            + (model.isIsland ? NotchModel.islandInset : 0)
        return NSRect(x: screen.frame.midX - w / 2, y: screen.frame.maxY - h, width: w, height: h)
    }

    private var hasOpenPopover: Bool {
        NSApp.windows.contains { $0 !== self && $0.isVisible && String(describing: type(of: $0)).contains("Popover") }
    }

    private func tick() {
        let cfg = state.config
        let p = NSEvent.mouseLocation
        let pressed = NSEvent.pressedMouseButtons & 1 != 0

        if model.expanded {
            if openRect.insetBy(dx: -12, dy: -12).contains(p) || hasOpenPopover {
                lastInside = Date()
            } else if Date().timeIntervalSince(lastInside) > 0.35 {
                setExpanded(false)
            }
            return
        }

        // Fast path: pointer nowhere near the top of this screen → nothing to do.
        if let top = currentScreen?.frame.maxY, p.y < top - 90 {
            if !pressed && wasPressed { lastPressEnd = Date() }
            wasPressed = pressed
            hoverStart = nil
            hoverAnchor = nil
            return
        }

        // Track presses: clicking or dragging up here (browser tabs!) must not open the notch.
        let dragBoard = NSPasteboard(name: .drag)
        let pressBegan = pressed && !wasPressed
        if pressBegan { dragCountAtPress = dragBoard.changeCount }
        if !pressed && wasPressed { lastPressEnd = Date() }
        wasPressed = pressed

        // Only the notch itself counts, not the space around it.
        let near = hoverRect.contains(p)

        // Dragging a *file* toward the notch opens the shelf. Tab drags aren't files, so they're ignored.
        if cfg.notchOpenOnDrag, cfg.notchShelf, pressed,
           dragBoard.changeCount != dragCountAtPress,
           dragBoard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]),
           collapsedRect.insetBy(dx: -40, dy: -30).contains(p) {
            model.tab = .shelf
            setExpanded(true)
            return
        }

        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let clickOnly = !cfg.notchOpenOnHover || (cfg.notchClickInBrowsers && Self.browsers.contains(front))
        if clickOnly {
            if near && pressBegan { setExpanded(true) }
            return
        }

        // Hover: the pointer has to rest on the notch, with no button held and no click just now.
        guard near, !pressed, Date().timeIntervalSince(lastPressEnd) > 0.6 else {
            hoverStart = nil
            hoverAnchor = nil
            return
        }
        if let anchor = hoverAnchor, hypot(p.x - anchor.x, p.y - anchor.y) > 14 {
            // Still moving (on the way to a tab or menu): restart the wait.
            hoverStart = Date()
            hoverAnchor = p
        } else if hoverStart == nil {
            hoverStart = Date()
            hoverAnchor = p
        }
        if let start = hoverStart, Date().timeIntervalSince(start) >= cfg.notchHoverDelay {
            setExpanded(true)
        }
    }

    /// The hardware notch (or island) itself, plus a hair of slack.
    private var hoverRect: NSRect {
        guard let screen = currentScreen else { return .zero }
        let size = model.notchSize
        let inset = model.isIsland ? NotchModel.islandInset : 0
        return NSRect(x: screen.frame.midX - size.width / 2 - 3,
                      y: screen.frame.maxY - size.height - inset,
                      width: size.width + 6,
                      height: size.height + inset + 1)
    }

    /// Music playing → the player. Nothing playing → Today. (Dragging a file still opens the shelf.)
    private func pickOpeningTab() {
        guard model.tab == .home || model.tab == .calendar else { return }
        let tabs = NotchModel.tabs(state.config)
        let playing = NowPlayingModel.shared.isPlaying
        if playing, tabs.contains(.home) {
            model.tab = .home
        } else if !playing, state.config.notchTodayWhenIdle, tabs.contains(.calendar) {
            model.tab = .calendar
        }
    }

    private func setExpanded(_ open: Bool) {
        guard open != model.expanded else { return }
        hoverStart = nil
        lastInside = Date()
        ignoresMouseEvents = !open
        if open && state.config.notchHaptics {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        if open { pickOpeningTab() }
        withAnimation(.spring(response: 0.38, dampingFraction: open ? 0.78 : 0.9)) {
            model.expanded = open
        }
    }
}

// MARK: - Controller

/// Creates or removes the notch window as settings and displays change.
final class NotchController {
    private let state: AppState
    private var panel: NotchPanel?
    private var cancellable: AnyCancellable?

    init(state: AppState) {
        self.state = state
        cancellable = state.$config
            .map { "\($0.notchEnabled)|\($0.notchFakeOnOtherMacs)|\($0.notchIsland)" }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.rebuild() } }
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification,
                                               object: nil)
    }

    @objc private func screensChanged() { rebuild() }

    func rebuild() {
        panel?.teardown()
        panel = nil
        let cfg = state.config
        guard cfg.notchEnabled, let screen = NotchGeometry.screen(allowFake: cfg.notchFakeOnOtherMacs) else { return }
        panel = NotchPanel(state: state, screen: screen)
    }
}
