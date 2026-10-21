import AppKit
import SwiftUI
import Combine

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

/// Per-panel state the SwiftUI content reads (each display can shrink to fit separately).
final class PanelModel: ObservableObject {
    @Published var fitScale: CGFloat = 1
}

/// A borderless, non-activating floating panel that holds one dock on one display.
/// It measures the SwiftUI content, centers itself on the screen edge,
/// and (with auto-hide on) slides off that edge like the macOS Dock.
final class DockPanel: NSPanel {
    private let state: AppState
    let model = PanelModel()
    private var controller: NSHostingController<AnyView>!
    private var contentSize = CGSize(width: 600, height: 100)
    private var cancellables = Set<AnyCancellable>()
    private var tickTimer: Timer?
    private var lastMouseInside = Date()
    private var isRevealed = true
    private var userHidden = false

    /// The display this dock lives on.
    private(set) var displayID: CGDirectDisplayID
    /// When true, the dock moves to whichever display you push the pointer against the edge of.
    var followsPointer = false
    /// Called when this panel's fit scale changes, so Settings can show it.
    var onFitChange: (() -> Void)?

    init(state: AppState, displayID: CGDirectDisplayID, hidden: Bool) {
        self.state = state
        self.displayID = displayID
        self.userHidden = hidden
        super.init(contentRect: NSRect(x: 0, y: 0, width: 600, height: 100),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)

        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false               // the SwiftUI backdrop draws its own shadow
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        animationBehavior = .none

        let root = DockRootView(onSize: { [weak self] _ in self?.remeasure() })
            .environmentObject(state)
            .environmentObject(model)
        let controller = NSHostingController(rootView: AnyView(root))
        controller.sizingOptions = []   // we size and place the panel ourselves
        self.controller = controller
        contentView = controller.view

        state.$config
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                // Run after the new config has been applied and laid out.
                DispatchQueue.main.async { self?.remeasure(force: true) }
            }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(self, selector: #selector(newScreenshot),
                                               name: .driftdockNewScreenshot, object: nil)
        startTicking()
    }

    /// Pop an auto-hidden dock up for a few seconds so a fresh screenshot is easy to grab.
    @objc private func newScreenshot() {
        let cfg = state.config
        guard cfg.revealOnScreenshot, cfg.autoHide, !userHidden,
              cfg.widgets.contains(where: { $0.kind == .screenshots && $0.enabled }) else { return }
        // In follow-the-pointer mode only the dock on the pointer's display needs to show.
        if followsPointer || NSScreen.screens.count == 1 || currentScreen.map({ NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) == true {
            lastMouseInside = Date().addingTimeInterval(4)
            setRevealed(true)
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func present() {
        guard !userHidden else { return }
        remeasure(force: true)
        orderFrontRegardless()
    }

    func setUserHidden(_ hidden: Bool) {
        userHidden = hidden
        if hidden {
            orderOut(nil)
        } else {
            isRevealed = true
            ignoresMouseEvents = false
            present()
        }
    }

    /// Stops timers and removes the panel. Call before dropping it.
    func teardown() {
        tickTimer?.invalidate()
        tickTimer = nil
        cancellables.removeAll()
        NotificationCenter.default.removeObserver(self)
        orderOut(nil)
    }

    func screensChanged() {
        remeasure(force: true)
    }

    private func move(to screen: NSScreen) {
        displayID = screen.displayID
        isRevealed = true
        ignoresMouseEvents = false
        lastMouseInside = Date()
        remeasure(force: true)
        orderFrontRegardless()
    }

    // MARK: Sizing

    /// Ask SwiftUI for the content's ideal size, then reposition if it changed.
    private func remeasure(force: Bool = false) {
        let fit = controller.sizeThatFits(in: NSSize(width: 10_000, height: 10_000))
        let size = CGSize(width: ceil(fit.width), height: ceil(fit.height))
        guard size.width > 1, size.height > 1 else { return }
        if adjustFitScale(for: size) { return } // SwiftUI re-renders, then we measure again
        if force || abs(size.width - contentSize.width) > 0.5 || abs(size.height - contentSize.height) > 0.5 {
            contentSize = size
            applyFrame(animated: false)
        }
    }

    /// Shrinks the dock just enough to fit its display, and grows it back when there's room.
    /// Returns true if the scale changed.
    private func adjustFitScale(for size: CGSize) -> Bool {
        guard let screen = currentScreen else { return false }
        let horizontal = state.config.edge.isHorizontal
        let edgeGap = max(CGFloat(state.config.margin), 6) * 2
        let available = horizontal ? screen.frame.width - edgeGap : screen.visibleFrame.height - edgeGap
        let measured = horizontal ? size.width : size.height
        let fixed = DockRootView.shadowPad * 2            // shadow padding, which doesn't scale
        let current = model.fitScale
        let ideal = (measured - fixed) / current + fixed  // size at 100%
        let target = min(1, max(0.4, (available - fixed) / max(ideal - fixed, 1)))
        let rounded = (target * 1000).rounded(.down) / 1000
        guard abs(rounded - current) > 0.004 else { return false }
        model.fitScale = rounded
        onFitChange?()
        DispatchQueue.main.async { [weak self] in self?.remeasure(force: true) }
        return true
    }

    // MARK: Geometry

    /// This dock's display, falling back to the main (menu bar) display if it was unplugged.
    var currentScreen: NSScreen? {
        NSScreen.screens.first { $0.displayID == displayID } ?? NSScreen.screens.first
    }

    /// Where the dock sits when visible.
    private func shownFrame() -> NSRect? {
        guard let screen = currentScreen else { return nil }
        let sf = screen.frame
        let vf = screen.visibleFrame
        let cfg = state.config
        let m = CGFloat(cfg.margin)
        let w = contentSize.width
        let h = contentSize.height
        // When we replace the system Dock, hug the real screen edge instead of
        // the area the (now hidden) Dock used to reserve.
        let edgeFrame = cfg.replaceSystemDock ? sf : vf

        func alongX() -> CGFloat {
            switch cfg.align {
            case .leading: return sf.minX + m
            case .center: return sf.midX - w / 2      // centered on the whole screen, like the Dock
            case .trailing: return sf.maxX - w - m
            }
        }
        func alongY() -> CGFloat {
            switch cfg.align {
            case .leading: return vf.maxY - h - m
            case .center: return vf.midY - h / 2
            case .trailing: return vf.minY + m
            }
        }

        // The window has transparent shadow room around the dock. Let the edge-side
        // part hang off the screen so the dock itself sits `margin` points from the edge,
        // like the macOS Dock.
        let pad = DockRootView.shadowPad
        let origin: CGPoint
        switch cfg.edge {
        case .bottom: origin = CGPoint(x: alongX(), y: edgeFrame.minY + m - pad)
        case .top:    origin = CGPoint(x: alongX(), y: vf.maxY - h - m + pad)
        case .left:   origin = CGPoint(x: edgeFrame.minX + m - pad, y: alongY())
        case .right:  origin = CGPoint(x: edgeFrame.maxX - w - m + pad, y: alongY())
        }
        return NSRect(origin: origin, size: contentSize).integral
    }

    /// Same frame, pushed just past the screen edge.
    private func hiddenFrame() -> NSRect? {
        guard let shown = shownFrame(), let sf = currentScreen?.frame else { return nil }
        var f = shown
        switch state.config.edge {
        case .bottom: f.origin.y = sf.minY - f.height - 2
        case .top:    f.origin.y = sf.maxY + 2
        case .left:   f.origin.x = sf.minX - f.width - 2
        case .right:  f.origin.x = sf.maxX + 2
        }
        return f
    }

    private func applyFrame(animated: Bool) {
        guard let target = isRevealed ? shownFrame() : hiddenFrame() else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.28
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                animator().setFrame(target, display: true)
            }
        } else if frame != target {
            setFrame(target, display: true)
        }
    }

    // MARK: Auto-hide (Dock-style slide) and following the pointer

    private func startTicking() {
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private var hasOpenPopover: Bool {
        NSApp.windows.contains { $0 !== self && $0.isVisible && String(describing: type(of: $0)).contains("Popover") }
    }

    private var ticks = 0

    private func tick() {
        // Catch size changes SwiftUI didn't report (e.g. a widget growing).
        ticks += 1
        if ticks % 100 == 0 { remeasure() }   // safety net; SwiftUI reports real size changes

        guard !userHidden else { return }
        let p = NSEvent.mouseLocation

        // Like the macOS Dock: push the pointer against the dock edge of another
        // display and the dock moves there.
        if followsPointer,
           let pointerScreen = NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) }),
           pointerScreen.displayID != displayID,
           pressedAgainstEdge(p, of: pointerScreen.frame) {
            move(to: pointerScreen)
            return
        }

        guard state.config.autoHide else {
            if !isRevealed { setRevealed(true) }
            return
        }
        guard let shown = shownFrame(), let sf = currentScreen?.frame else { return }

        if isRevealed {
            if shown.insetBy(dx: -10, dy: -10).contains(p) || hasOpenPopover || state.arranging {
                lastMouseInside = Date()
            } else if Date().timeIntervalSince(lastMouseInside) > 0.5 {
                setRevealed(false)
            }
        } else if pressedAgainstEdge(p, of: sf, near: shown) {
            lastMouseInside = Date()
            setRevealed(true)
        }
    }

    /// True when the pointer is pressed against the dock's edge of a display.
    /// With `near`, it also has to be within the dock's span.
    private func pressedAgainstEdge(_ p: CGPoint, of sf: NSRect, near shown: NSRect? = nil) -> Bool {
        let slack: CGFloat = 60
        let spanX = shown.map { p.x >= $0.minX - slack && p.x <= $0.maxX + slack } ?? true
        let spanY = shown.map { p.y >= $0.minY - slack && p.y <= $0.maxY + slack } ?? true
        switch state.config.edge {
        case .bottom: return p.y <= sf.minY + 2 && spanX
        case .top:    return p.y >= sf.maxY - 2 && spanX
        case .left:   return p.x <= sf.minX + 2 && spanY
        case .right:  return p.x >= sf.maxX - 2 && spanY
        }
    }

    private func setRevealed(_ show: Bool) {
        guard show != isRevealed else { return }
        isRevealed = show
        ignoresMouseEvents = !show
        applyFrame(animated: true)
    }
}

// MARK: - Manager

/// Owns one dock per display (or a single one), depending on Settings → General → Displays.
final class DockManager {
    private let state: AppState
    private var panels: [DockPanel] = []
    private var hidden = false
    private var cancellable: AnyCancellable?

    init(state: AppState) {
        self.state = state
        cancellable = state.$config
            .map(\.display)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.rebuild() } }
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification,
                                               object: nil)
    }

    func toggleVisibility() {
        hidden.toggle()
        panels.forEach { $0.setUserHidden(hidden) }
    }

    @objc private func screensChanged() {
        // Displays plugged in or removed: rebuild for "all displays" / a missing screen.
        let wanted = Set(targets().map(\.id))
        let have = Set(panels.map(\.displayID))
        if state.config.display == DisplayChoice.follow || wanted == have {
            panels.forEach { $0.screensChanged() }
        } else {
            rebuild()
        }
    }

    private func targets() -> [(id: CGDirectDisplayID, follow: Bool)] {
        let screens = NSScreen.screens
        guard let main = screens.first else { return [] }
        switch state.config.display {
        case DisplayChoice.all:
            return screens.map { ($0.displayID, false) }
        case DisplayChoice.follow:
            // Keep the dock where it is if it's following and that screen still exists.
            let current = panels.first.map(\.displayID).flatMap { id in screens.first { $0.displayID == id } }
            return [((current ?? main).displayID, true)]
        case let choice where choice.hasPrefix(DisplayChoice.screenPrefix):
            let label = String(choice.dropFirst(DisplayChoice.screenPrefix.count))
            let match = DisplayChoice.labeledScreens().first { $0.label == label }?.screen
            return [((match ?? main).displayID, false)]
        default:
            return [(main.displayID, false)]
        }
    }

    func rebuild() {
        let wanted = targets()
        panels.forEach { $0.teardown() }
        panels = wanted.map { target in
            let panel = DockPanel(state: state, displayID: target.id, hidden: hidden)
            panel.followsPointer = target.follow
            panel.onFitChange = { [weak self] in self?.reportFit() }
            return panel
        }
        panels.forEach { $0.present() }
        reportFit()
    }

    /// Settings shows the smallest shrink across displays.
    private func reportFit() {
        let smallest = panels.map(\.model.fitScale).min() ?? 1
        if abs(state.fitScale - smallest) > 0.001 { state.fitScale = smallest }
    }
}

/// Values stored in `Config.display`.
enum DisplayChoice {
    static let main = "main"
    static let follow = "follow"
    static let all = "all"
    static let screenPrefix = "screen:"

    /// Screens with human-readable labels; identical monitors get " 2", " 3"…
    static func labeledScreens() -> [(label: String, screen: NSScreen)] {
        var seen: [String: Int] = [:]
        return NSScreen.screens.map { screen in
            let name = screen.localizedName
            seen[name, default: 0] += 1
            let n = seen[name]!
            return (n == 1 ? name : "\(name) \(n)", screen)
        }
    }
}
