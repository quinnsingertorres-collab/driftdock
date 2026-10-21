import AppKit
import ApplicationServices

/// Places a window should snap to, as fractions of the screen's usable area.
enum SnapTarget: String, CaseIterable {
    case leftHalf, rightHalf, topHalf, bottomHalf, maximize, center
    case topLeft, topRight, bottomLeft, bottomRight
    case leftThird, centerThird, rightThird, leftTwoThirds, rightTwoThirds

    var title: String {
        switch self {
        case .leftHalf: return "Left Half"
        case .rightHalf: return "Right Half"
        case .topHalf: return "Top Half"
        case .bottomHalf: return "Bottom Half"
        case .maximize: return "Maximize"
        case .center: return "Center"
        case .topLeft: return "Top Left"
        case .topRight: return "Top Right"
        case .bottomLeft: return "Bottom Left"
        case .bottomRight: return "Bottom Right"
        case .leftThird: return "Left Third"
        case .centerThird: return "Center Third"
        case .rightThird: return "Right Third"
        case .leftTwoThirds: return "Left Two Thirds"
        case .rightTwoThirds: return "Right Two Thirds"
        }
    }

    /// The target rect in Cocoa coordinates (origin bottom-left), inset by `gap`.
    func rect(in vf: NSRect, current: NSRect, gap: CGFloat) -> NSRect {
        let w = vf.width, h = vf.height
        var r: NSRect
        switch self {
        case .leftHalf: r = NSRect(x: vf.minX, y: vf.minY, width: w / 2, height: h)
        case .rightHalf: r = NSRect(x: vf.midX, y: vf.minY, width: w / 2, height: h)
        case .topHalf: r = NSRect(x: vf.minX, y: vf.midY, width: w, height: h / 2)
        case .bottomHalf: r = NSRect(x: vf.minX, y: vf.minY, width: w, height: h / 2)
        case .maximize: r = vf
        case .center:
            let size = NSSize(width: min(current.width, w), height: min(current.height, h))
            return NSRect(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2, width: size.width, height: size.height).integral
        case .topLeft: r = NSRect(x: vf.minX, y: vf.midY, width: w / 2, height: h / 2)
        case .topRight: r = NSRect(x: vf.midX, y: vf.midY, width: w / 2, height: h / 2)
        case .bottomLeft: r = NSRect(x: vf.minX, y: vf.minY, width: w / 2, height: h / 2)
        case .bottomRight: r = NSRect(x: vf.midX, y: vf.minY, width: w / 2, height: h / 2)
        case .leftThird: r = NSRect(x: vf.minX, y: vf.minY, width: w / 3, height: h)
        case .centerThird: r = NSRect(x: vf.minX + w / 3, y: vf.minY, width: w / 3, height: h)
        case .rightThird: r = NSRect(x: vf.minX + 2 * w / 3, y: vf.minY, width: w / 3, height: h)
        case .leftTwoThirds: r = NSRect(x: vf.minX, y: vf.minY, width: 2 * w / 3, height: h)
        case .rightTwoThirds: r = NSRect(x: vf.minX + w / 3, y: vf.minY, width: 2 * w / 3, height: h)
        }
        return r.insetBy(dx: gap / 2, dy: gap / 2).integral
    }
}

/// Moves and resizes other apps' windows through the Accessibility API.
final class WindowSnapper {
    static let shared = WindowSnapper()
    private var previousFrames: [CFHashCode: NSRect] = [:]

    var isTrusted: Bool { AXIsProcessTrusted() }

    /// Snaps the frontmost app's focused window.
    func snapFocused(_ target: SnapTarget) {
        guard let window = focusedWindow() else { return }
        snap(window, to: target)
    }

    func snap(_ window: AXUIElement, to target: SnapTarget) {
        guard let current = frame(of: window) else { return }
        let screen = Self.screen(containing: current)
        guard let vf = usableFrame(on: screen) else { return }
        let gap = CGFloat(AppState.shared.config.snapGap)
        previousFrames[CFHash(window)] = current
        if previousFrames.count > 40 { previousFrames.removeAll() }
        setFrame(of: window, to: target.rect(in: vf, current: current, gap: gap))
    }

    /// Puts the focused window back where it was before the last snap.
    func restoreFocused() {
        guard let window = focusedWindow(), let old = previousFrames[CFHash(window)] else { return }
        setFrame(of: window, to: old)
        previousFrames[CFHash(window)] = nil
    }

    func focusedWindow() -> AXUIElement? {
        guard isTrusted else {
            Paster.requestAccess()
            LiveActivityCenter.shared.flash(symbol: "hand.raised.fill", text: "Allow Accessibility for snapping", seconds: 3)
            return nil
        }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// The screen's visible area, leaving room for Driftdock when it reserves space at the bottom.
    func usableFrame(on screen: NSScreen?) -> NSRect? {
        guard let screen else { return nil }
        var vf = screen.visibleFrame
        let cfg = AppState.shared.config
        if cfg.snapAvoidDock && !cfg.autoHide && cfg.edge == .bottom {
            let dockHeight = 64 * CGFloat(cfg.scale) * 1.28 + CGFloat(cfg.margin)
            vf.origin.y += dockHeight
            vf.size.height -= dockHeight
        }
        return vf
    }

    // MARK: AX geometry (AX uses a top-left origin on the primary display)

    private static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    static func screen(containing r: NSRect) -> NSScreen? {
        let center = NSPoint(x: r.midX, y: r.midY)
        return NSScreen.screens.first { NSMouseInRect(center, $0.frame, false) } ?? NSScreen.screens.first
    }

    func frame(of window: AXUIElement) -> NSRect? {
        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        // Convert to Cocoa coordinates.
        return NSRect(x: pos.x, y: Self.primaryHeight - pos.y - size.height, width: size.width, height: size.height)
    }

    func setFrame(of window: AXUIElement, to r: NSRect) {
        var pos = CGPoint(x: r.minX, y: Self.primaryHeight - r.maxY)
        var size = CGSize(width: r.width, height: r.height)
        guard let posValue = AXValueCreate(.cgPoint, &pos), let sizeValue = AXValueCreate(.cgSize, &size) else { return }
        // Size, move, size again: some apps clamp size to the screen they're currently on.
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posValue)
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
    }
}

// MARK: - Drag to screen edges

/// Drag a window's title bar to a screen edge or corner; a preview shows where it will land.
final class DragSnapper {
    static let shared = DragSnapper()

    private var monitor: Any?
    private var downPoint: NSPoint?
    private var dragWindow: AXUIElement?
    private var startFrame: NSRect?
    private var confirmed = false
    private var lastCheck: TimeInterval = 0
    private var zone: SnapTarget?
    private let preview = SnapPreview()

    func setEnabled(_ on: Bool) {
        if on, monitor == nil {
            monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] e in
                self?.handle(e)
            }
        } else if !on, let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
            reset()
        }
    }

    private func reset() {
        downPoint = nil
        dragWindow = nil
        startFrame = nil
        confirmed = false
        zone = nil
        preview.hide()
    }

    private func handle(_ e: NSEvent) {
        let p = NSEvent.mouseLocation
        switch e.type {
        case .leftMouseDown:
            reset()
            downPoint = p
        case .leftMouseDragged:
            guard let down = downPoint, WindowSnapper.shared.isTrusted else { return }
            if dragWindow == nil, hypot(p.x - down.x, p.y - down.y) > 12 {
                // Whatever window is focused now is the one being dragged (if it actually moves).
                dragWindow = WindowSnapper.shared.focusedWindow()
                startFrame = dragWindow.flatMap { WindowSnapper.shared.frame(of: $0) }
                lastCheck = e.timestamp
                return
            }
            guard let window = dragWindow, let start = startFrame else { return }
            if !confirmed {
                guard e.timestamp - lastCheck > 0.08 else { return }
                lastCheck = e.timestamp
                guard let now = WindowSnapper.shared.frame(of: window) else { return }
                // Moved but kept its size: it's a title-bar drag, not a resize.
                let moved = abs(now.minX - start.minX) > 4 || abs(now.minY - start.minY) > 4
                let sameSize = abs(now.width - start.width) < 2 && abs(now.height - start.height) < 2
                confirmed = moved && sameSize
                if !confirmed { return }
            }
            updateZone(at: p, window: window)
        case .leftMouseUp:
            if confirmed, let window = dragWindow, let target = zone {
                // Let the app finish its own drag first.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    WindowSnapper.shared.snap(window, to: target)
                }
            }
            reset()
        default:
            break
        }
    }

    private func updateZone(at p: NSPoint, window: AXUIElement) {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) }) else { return }
        let f = screen.frame
        let edge: CGFloat = 4
        let corner: CGFloat = 80
        let atLeft = p.x <= f.minX + edge
        let atRight = p.x >= f.maxX - edge
        let atTop = p.y >= f.maxY - edge
        let atBottom = p.y <= f.minY + edge

        var target: SnapTarget?
        if atLeft { target = p.y > f.maxY - corner ? .topLeft : (p.y < f.minY + corner ? .bottomLeft : .leftHalf) }
        else if atRight { target = p.y > f.maxY - corner ? .topRight : (p.y < f.minY + corner ? .bottomRight : .rightHalf) }
        else if atTop { target = p.x < f.minX + corner ? .topLeft : (p.x > f.maxX - corner ? .topRight : .maximize) }
        else if atBottom { target = p.x < f.minX + corner ? .bottomLeft : (p.x > f.maxX - corner ? .bottomRight : nil) }

        guard target != zone else { return }
        zone = target
        if let target, let vf = WindowSnapper.shared.usableFrame(on: screen),
           let current = WindowSnapper.shared.frame(of: window) {
            let gap = CGFloat(AppState.shared.config.snapGap)
            preview.show(target.rect(in: vf, current: current, gap: gap))
        } else {
            preview.hide()
        }
    }
}

/// The translucent rectangle that shows where a dragged window will snap.
final class SnapPreview {
    private lazy var window: NSWindow = {
        let w = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = .floating
        w.ignoresMouseEvents = true
        w.hasShadow = false
        w.collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary]
        let v = NSView()
        v.wantsLayer = true
        v.layer?.cornerRadius = 12
        v.layer?.borderWidth = 2
        w.contentView = v
        return w
    }()

    func show(_ rect: NSRect) {
        let accent = NSColor(AppState.shared.accent)
        window.contentView?.layer?.backgroundColor = accent.withAlphaComponent(0.18).cgColor
        window.contentView?.layer?.borderColor = accent.withAlphaComponent(0.7).cgColor
        if !window.isVisible {
            window.setFrame(rect.insetBy(dx: rect.width * 0.1, dy: rect.height * 0.1), display: false)
            window.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            window.animator().setFrame(rect, display: true)
        }
    }

    func hide() {
        if window.isVisible { window.orderOut(nil) }
    }
}
