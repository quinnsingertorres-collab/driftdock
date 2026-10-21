import Foundation
import AppKit
import SwiftUI
import Combine
import Network
import CoreGraphics

/// The Glide settings that decide what's running. Speed is left out on purpose:
/// changing it adjusts the live connection instead of restarting it.
struct GlideSetup: Equatable {
    var enabled: Bool
    var role: String       // "receive" or "share"
    var host: String
    var edge: String       // "left" or "right"
    var flashes: Bool

    init(_ c: Config) {
        enabled = c.glideEnabled
        role = c.glideRole
        host = c.glideHost.trimmingCharacters(in: .whitespacesAndNewlines)
        edge = c.glideEdge
        flashes = c.glideFlashes
    }
}

/// Runs Glide inside Driftdock and reports what it's doing to Settings and the menu bar.
final class GlideController: ObservableObject {
    static let shared = GlideController()

    enum Status: Equatable {
        case off
        case waiting                 // receiver listening
        case connecting(String)      // sharer dialing
        case connected(String)       // link up; peer description
        case remote(String)          // sharer: cursor is on the other computer
        case needsPermission(String)
        case failed(String)

        var text: String {
            switch self {
            case .off: return "Off"
            case .waiting: return "Waiting for the other computer…"
            case .connecting(let host): return "Connecting to \(host)…"
            case .connected(let peer): return "Connected to \(peer)"
            case .remote(let peer): return "Controlling the \(peer)"
            case .needsPermission(let what): return "Needs \(what) permission"
            case .failed(let why): return why
            }
        }

        var color: NSColor {
            switch self {
            case .off: return .secondaryLabelColor
            case .waiting, .connecting: return .systemOrange
            case .connected, .remote: return .systemGreen
            case .needsPermission, .failed: return .systemRed
            }
        }
    }

    @Published private(set) var status: Status = .off {
        didSet { if status != oldValue { announce(from: oldValue, to: status) } }
    }
    /// Who we were linked to, so "disconnected" can say from what.
    private var lastPeer: String?
    @Published private(set) var addresses: [String] = GlideWire.localIPv4()

    private var receiver: GlideReceiver?
    private var sharer: GlideSharer?
    private var setup: GlideSetup?
    private var cancellables = Set<AnyCancellable>()

    private init() {}

    func bind(_ state: AppState) {
        state.$config
            .map(GlideSetup.init)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.apply($0) }
            .store(in: &cancellables)

        state.$config
            .map(\.glideSpeed)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.sharer?.speed = $0 }
            .store(in: &cancellables)

        state.$config
            .map(\.glideHotkey)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.applyHotkey($0) }
            .store(in: &cancellables)
    }

    /// Starts over with the current settings (the Settings "Reconnect" button).
    func restart() {
        guard let s = setup else { return }
        setup = nil
        apply(s)
    }

    /// Pulls the cursor back to this Mac if it's on the other computer.
    func bringHome() {
        sharer?.leave(notify: true)
    }

    var isOn: Bool { AppState.shared.config.glideEnabled }
    var isRemote: Bool { if case .remote = status { return true } else { return false } }

    /// Turns Glide on, or starts the link over if it's already on.
    func connect() {
        if isOn { restart() } else { AppState.shared.config.glideEnabled = true }
    }

    /// Drops the other computer and stops listening / dialing until you connect again.
    func disconnect() {
        bringHome()
        AppState.shared.config.glideEnabled = false
    }

    /// For the menu and the ⌃⌥⌘K hotkey.
    func toggle() {
        let wasOn = isOn
        if wasOn { disconnect() } else { connect() }
        // Disconnecting shows its own banner (from the status change); connecting gets a quick note.
        if !wasOn {
            LiveActivityCenter.shared.flash(symbol: "cable.connector", text: "Glide connecting…")
        }
    }

    private func applyHotkey(_ on: Bool) {
        if on {
            // ⌃⌥⌘K — keyCode 40 is K; Carbon flags: cmd 0x0100, option 0x0800, control 0x1000.
            HotKeyCenter.shared.register(id: 700, keyCode: 40, modifiers: 0x0100 | 0x0800 | 0x1000) { [weak self] in
                self?.toggle()
            }
        } else {
            HotKeyCenter.shared.unregister(id: 700)
        }
    }

    func refreshAddresses() {
        addresses = GlideWire.localIPv4()
    }

    private func apply(_ s: GlideSetup) {
        guard s != setup else { return }
        setup = s
        stopAll()
        refreshAddresses()
        guard s.enabled else {
            status = .off
            return
        }

        if s.role == "share" {
            guard !s.host.isEmpty else {
                status = .failed("Enter the other computer's IP address")
                return
            }
            if !CGPreflightListenEventAccess() {
                CGRequestListenEventAccess()
                status = .needsPermission("Input Monitoring")
                return
            }
            if !AXIsProcessTrusted() {
                Paster.requestAccess()
                status = .needsPermission("Accessibility")
                return
            }
            let sh = GlideSharer(host: s.host, edgeRight: s.edge != "left", speed: AppState.shared.config.glideSpeed)
            sh.onStatus = { [weak self] in self?.update($0) }
            sharer = sh
            sh.start()
        } else {
            if !AXIsProcessTrusted() {
                Paster.requestAccess()
                status = .needsPermission("Accessibility")
                return
            }
            let r = GlideReceiver()
            r.onStatus = { [weak self] in self?.update($0) }
            receiver = r
            r.start()
        }
    }

    private func update(_ new: Status) {
        status = new   // announce(from:to:) runs from didSet
    }

    private static func isLinked(_ s: Status) -> Bool {
        switch s {
        case .connected, .remote: return true
        default: return false
        }
    }

    /// Connected / disconnected cards by the notch, plus a quick note when the pointer crosses over.
    private func announce(from old: Status, to new: Status) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.announce(from: old, to: new) }
            return
        }
        guard AppState.shared.config.glideFlashes else { return }
        let wasLinked = Self.isLinked(old), isLinked = Self.isLinked(new)

        if case .connected(let peer) = new { lastPeer = peer }
        if case .remote(let peer) = new { lastPeer = peer }

        if !wasLinked && isLinked {
            let peer = lastPeer ?? "your other computer"
            LiveActivityCenter.shared.showBanner(.init(
                symbol: "cable.connector", tint: .green, title: "Glide connected",
                subtitle: "Sharing your mouse and keyboard with the \(peer)", trailing: "checkmark"), seconds: 3.5)
        } else if wasLinked && !isLinked {
            let peer = lastPeer ?? "other computer"
            let detail: String
            switch new {
            case .off: detail = "Turned off. Press ⌃⌥⌘K to connect again"
            case .waiting, .connecting: detail = "Lost the \(peer). Reconnecting…"
            case .failed(let why): detail = why
            case .needsPermission(let what): detail = "Needs \(what) permission"
            default: detail = "The \(peer) went away"
            }
            LiveActivityCenter.shared.showBanner(.init(
                symbol: "cable.connector.slash", tint: .red, title: "Glide disconnected",
                subtitle: detail, trailing: nil), seconds: 4)
        } else if case .connected = old, case .remote(let peer) = new {
            LiveActivityCenter.shared.flash(symbol: "cursorarrow.motionlines", text: "On the \(peer)", seconds: 1.2)
        }
    }

    private func stopAll() {
        sharer?.stop()
        sharer = nil
        receiver?.stop()
        receiver = nil
    }
}

// MARK: - Cursor hiding

enum GlideCursor {
    private static var allowed = false

    /// Driftdock is a background app, and macOS ignores cursor hiding from background apps
    /// unless this (long-standing, private) connection property is set. Fails quietly if it's gone.
    static func allowBackgroundHiding() {
        guard !allowed, let handle = dlopen(nil, RTLD_LAZY),
              let mainSym = dlsym(handle, "_CGSDefaultConnection"),
              let setSym = dlsym(handle, "CGSSetConnectionProperty") else { return }
        typealias MainConnection = @convention(c) () -> Int32
        typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
        let conn = unsafeBitCast(mainSym, to: MainConnection.self)()
        _ = unsafeBitCast(setSym, to: SetProperty.self)(conn, conn, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
        allowed = true
    }
}

// MARK: - Sharer (this Mac has the mouse)

final class GlideSharer {
    var onStatus: ((GlideController.Status) -> Void)?
    var speed: Double

    private let host: String
    private let edgeRight: Bool
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var conn: NWConnection?
    private var stopped = false

    private var connected = false
    private var remote = false
    private var peer = "PC"
    private var remoteSize = CGSize(width: 1920, height: 1080)
    private var scale = 1.0
    private var rx = 0.0, ry = 0.0
    private var cursorHidden = false
    private var local = CGRect.zero

    init(host: String, edgeRight: Bool, speed: Double) {
        self.host = host
        self.edgeRight = edgeRight
        self.speed = speed
    }

    func start() {
        local = Self.desktopBounds()
        guard installTap() else {
            onStatus?(.needsPermission("Input Monitoring"))
            return
        }
        connect()
    }

    func stop() {
        stopped = true
        leave(notify: true)
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tap = nil
        tapSource = nil
        conn?.cancel()
        conn = nil
    }

    static func desktopBounds() -> CGRect {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids.map { CGDisplayBounds($0) }.reduce(CGRect.null) { $0.union($1) }
    }

    // MARK: Networking

    private func connect() {
        guard !stopped else { return }
        onStatus?(.connecting(host))
        let c = NWConnection(host: NWEndpoint.Host(host), port: GlideWire.port, using: GlideWire.params())
        c.stateUpdateHandler = { [weak self] state in
            guard let self, self.conn === c else { return }
            switch state {
            case .ready:
                GlideWire.receiveLoop(c, onClose: { [weak self] in self?.dropped(c) }) { [weak self] in self?.handle($0) }
            case .failed, .waiting:
                self.dropped(c)
            default:
                break
            }
        }
        conn = c
        c.start(queue: .main)
    }

    private func handle(_ msg: GlideMsg) {
        guard msg.type == .hello else { return }
        remoteSize = CGSize(width: max(msg.d1, 1), height: max(msg.d2, 1))
        peer = msg.i1 == GlideWire.platformWindows ? "PC" : "Mac"
        local = Self.desktopBounds()
        scale = remoteSize.height / max(local.height, 1)
        connected = true
        onStatus?(.connected(peer))
    }

    private func dropped(_ c: NWConnection) {
        guard conn === c else { return }
        if remote { leave(notify: false) }
        connected = false
        c.cancel()
        conn = nil
        guard !stopped else { return }
        onStatus?(.connecting(host))
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.connect() }
    }

    private func send(_ msg: GlideMsg) {
        conn?.send(content: msg.encode(), completion: .idempotent)
    }

    // MARK: Event tap

    private func installTap() -> Bool {
        let types: [CGEventType] = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
            .scrollWheel, .keyDown, .keyUp, .flagsChanged,
        ]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let me = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, info in
                guard let info else { return Unmanaged.passUnretained(event) }
                return Unmanaged<GlideSharer>.fromOpaque(info).takeUnretainedValue().onEvent(type, event)
            },
            userInfo: me
        ) else { return false }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        tapSource = source
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func onEvent(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        guard remote else {
            if connected, isMove(type) {
                let p = event.location
                let dx = event.getDoubleValueField(.mouseEventDeltaX)
                let hit = edgeRight ? (dx > 0 && p.x >= local.maxX - 1) : (dx < 0 && p.x <= local.minX)
                if hit {
                    enter(localY: p.y)
                    return nil
                }
            }
            return Unmanaged.passUnretained(event)
        }

        // Cursor is on the other computer: forward everything, let nothing through here.
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            let dx = event.getDoubleValueField(.mouseEventDeltaX) * scale * speed
            let dy = event.getDoubleValueField(.mouseEventDeltaY) * scale * speed
            rx += dx
            ry = min(max(ry + dy, 0), remoteSize.height - 1)
            if (edgeRight && rx < 0) || (!edgeRight && rx > remoteSize.width - 1) {
                leave(notify: true)
                return nil
            }
            rx = min(max(rx, 0), remoteSize.width - 1)
            send(GlideMsg(type: .move, i1: Int32(dx.rounded()), i2: Int32(dy.rounded()), d1: rx, d2: ry))

        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            let button = event.getIntegerValueField(.mouseEventButtonNumber)
            let down = type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown
            send(GlideMsg(type: .button, i1: Int32(button), i2: down ? 1 : 0))

        case .scrollWheel:
            // Mac: axis 1 positive = up, axis 2 positive = left. Wire: positive = up / right.
            let v = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
            let h = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
            send(GlideMsg(type: .scroll, d1: Double(v), d2: Double(-h)))

        case .keyDown, .keyUp:
            if type == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
                return nil   // the other computer makes its own key repeat
            }
            let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            // Escape hatch: Control-Option-Command-G always brings the cursor home.
            if type == .keyDown, code == 0x05,
               event.flags.contains([.maskControl, .maskAlternate, .maskCommand]) {
                leave(notify: true)
                return nil
            }
            // ⌃⌥⌘K disconnects even while the pointer is over there.
            if type == .keyDown, code == 0x28, AppState.shared.config.glideHotkey,
               event.flags.contains([.maskControl, .maskAlternate, .maskCommand]) {
                DispatchQueue.main.async { GlideController.shared.toggle() }
                return nil
            }
            if let hid = GlideKeys.macToHid[code] {
                send(GlideMsg(type: .key, i1: Int32(hid), i2: type == .keyDown ? 1 : 0))
            }

        case .flagsChanged:
            let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            if let mod = GlideKeys.macModifierKeys[code] {
                let down = event.flags.rawValue & mod.bit != 0
                send(GlideMsg(type: .key, i1: Int32(mod.hid), i2: down ? 1 : 0))
            } else if code == 0x39 {
                // Caps Lock: macOS reports the toggle; the PC wants a press and release.
                send(GlideMsg(type: .key, i1: 0x39, i2: 1))
                send(GlideMsg(type: .key, i1: 0x39, i2: 0))
            }

        default:
            break
        }
        return nil
    }

    private func isMove(_ t: CGEventType) -> Bool {
        t == .mouseMoved || t == .leftMouseDragged || t == .rightMouseDragged || t == .otherMouseDragged
    }

    // MARK: Crossing the edge

    private func enter(localY: Double) {
        remote = true
        rx = edgeRight ? 0 : remoteSize.width - 1
        ry = (localY - local.minY) / max(local.height, 1) * remoteSize.height
        CGAssociateMouseAndMouseCursorPosition(0)   // freeze the cursor here but keep getting movement
        GlideCursor.allowBackgroundHiding()
        if !cursorHidden { _ = CGDisplayHideCursor(CGMainDisplayID()); cursorHidden = true }
        send(GlideMsg(type: .enter, d1: rx, d2: ry))
        onStatus?(.remote(peer))
    }

    func leave(notify: Bool) {
        guard remote else { return }
        remote = false
        if notify { send(GlideMsg(type: .leave)) }
        let y = local.minY + ry / remoteSize.height * local.height
        let x = edgeRight ? local.maxX - 2 : local.minX + 1
        CGWarpMouseCursorPosition(CGPoint(x: x, y: y))
        CGAssociateMouseAndMouseCursorPosition(1)
        if cursorHidden { _ = CGDisplayShowCursor(CGMainDisplayID()); cursorHidden = false }
        if connected && !stopped { onStatus?(.connected(peer)) }
    }
}

// MARK: - Receiver (the other computer has the mouse)

final class GlideReceiver {
    var onStatus: ((GlideController.Status) -> Void)?

    private var listener: NWListener?
    private var conn: NWConnection?
    private let source = CGEventSource(stateID: .hidSystemState)

    private var pos = CGPoint.zero
    private var heldButtons = Set<Int32>()
    private var heldMods = Set<UInt16>()
    private var heldKeys = Set<UInt16>()

    // Windows doesn't send click counts, so double-clicks are worked out here.
    private var lastDown: (button: Int32, time: TimeInterval, pos: CGPoint)?
    private var clickCount: Int64 = 1

    func start() {
        do {
            let l = try NWListener(using: GlideWire.params(), on: GlideWire.port)
            l.service = NWListener.Service(name: Host.current().localizedName ?? "Mac", type: GlideWire.serviceType)
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            l.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.onStatus?(.waiting)
                case .failed(let error):
                    if case .posix(let code) = error, code == .EADDRINUSE {
                        self?.onStatus?(.failed("Port 24811 is busy. Quit any `glide receive` running in Terminal, then press Reconnect."))
                    } else {
                        self?.onStatus?(.failed("Couldn't listen: \(error.localizedDescription)"))
                    }
                default:
                    break
                }
            }
            l.start(queue: .main)
            listener = l
        } catch {
            onStatus?(.failed("Couldn't listen: \(error.localizedDescription)"))
        }
    }

    func stop() {
        releaseEverything()
        conn?.cancel()
        conn = nil
        listener?.cancel()
        listener = nil
    }

    private func accept(_ c: NWConnection) {
        conn?.cancel()
        releaseEverything()
        conn = c
        c.stateUpdateHandler = { [weak self] state in
            guard let self, self.conn === c, case .ready = state else { return }
            let screen = CGDisplayBounds(CGMainDisplayID())
            let hello = GlideMsg(type: .hello, i1: GlideWire.platformMac, d1: screen.width, d2: screen.height)
            c.send(content: hello.encode(), completion: .idempotent)
            self.onStatus?(.connected(self.describe(c.endpoint)))
            GlideWire.receiveLoop(c, onClose: { [weak self] in
                guard let self, self.conn === c else { return }
                self.conn = nil
                self.releaseEverything()
                self.onStatus?(.waiting)
            }) { [weak self] in self?.handle($0) }
        }
        c.start(queue: .main)
    }

    private func describe(_ endpoint: NWEndpoint) -> String {
        if case let .hostPort(host, _) = endpoint {
            var s = "\(host)"
            if let pct = s.firstIndex(of: "%") { s = String(s[..<pct]) }   // drop the interface suffix
            return s
        }
        return "the other computer"
    }

    private var flags: CGEventFlags {
        heldMods.reduce(CGEventFlags()) { $0.union(GlideKeys.modifierFlags[$1] ?? []) }
    }

    private func handle(_ m: GlideMsg) {
        switch m.type {
        case .enter:
            pos = CGPoint(x: m.d1, y: m.d2)
            postMouse(.mouseMoved, button: .left)
        case .move:
            pos = CGPoint(x: m.d1, y: m.d2)
            let (type, button) = dragType()
            postMouse(type, button: button, dx: m.i1, dy: m.i2)
        case .button:
            mouseButton(m.i1, down: m.i2 == 1)
        case .scroll:
            let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                            wheel1: Int32(m.d1.rounded()), wheel2: Int32(-m.d2.rounded()), wheel3: 0)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        case .key:
            key(UInt16(truncatingIfNeeded: m.i1), down: m.i2 == 1)
        case .leave:
            releaseEverything()
        case .hello:
            break
        }
    }

    private func dragType() -> (CGEventType, CGMouseButton) {
        if heldButtons.contains(0) { return (.leftMouseDragged, .left) }
        if heldButtons.contains(1) { return (.rightMouseDragged, .right) }
        if !heldButtons.isEmpty { return (.otherMouseDragged, .center) }
        return (.mouseMoved, .left)
    }

    private func mouseButton(_ n: Int32, down: Bool) {
        if down {
            let now = Date.timeIntervalSinceReferenceDate
            if let last = lastDown, last.button == n, now - last.time < NSEvent.doubleClickInterval,
               abs(last.pos.x - pos.x) < 5, abs(last.pos.y - pos.y) < 5 {
                clickCount += 1
            } else {
                clickCount = 1
            }
            lastDown = (n, now, pos)
            heldButtons.insert(n)
        } else {
            heldButtons.remove(n)
        }
        let type: CGEventType
        switch (n, down) {
        case (0, true): type = .leftMouseDown
        case (0, false): type = .leftMouseUp
        case (1, true): type = .rightMouseDown
        case (1, false): type = .rightMouseUp
        case (_, true): type = .otherMouseDown
        default: type = .otherMouseUp
        }
        postMouse(type, button: CGMouseButton(rawValue: UInt32(n)) ?? .center,
                  buttonNumber: Int64(n), clicks: clickCount)
    }

    private func postMouse(_ type: CGEventType, button: CGMouseButton, dx: Int32 = 0, dy: Int32 = 0,
                           buttonNumber: Int64? = nil, clicks: Int64? = nil) {
        guard let e = CGEvent(mouseEventSource: source, mouseType: type,
                              mouseCursorPosition: pos, mouseButton: button) else { return }
        e.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx))
        e.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy))
        if let buttonNumber { e.setIntegerValueField(.mouseEventButtonNumber, value: buttonNumber) }
        if let clicks { e.setIntegerValueField(.mouseEventClickState, value: clicks) }
        e.flags = flags
        e.post(tap: .cghidEventTap)
    }

    private func key(_ hid: UInt16, down: Bool) {
        guard let mac = GlideKeys.hidToMac[hid],
              let e = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(mac), keyDown: down) else { return }
        if GlideKeys.modifierFlags[hid] != nil {
            if down { heldMods.insert(hid) } else { heldMods.remove(hid) }
            e.type = .flagsChanged
        } else {
            if down { heldKeys.insert(hid) } else { heldKeys.remove(hid) }
        }
        e.flags = flags
        e.post(tap: .cghidEventTap)
    }

    /// Let go of anything still pressed so this Mac doesn't end up with a stuck key or drag.
    private func releaseEverything() {
        for n in heldButtons { mouseButton(n, down: false) }
        for k in heldKeys { key(k, down: false) }
        for k in heldMods { key(k, down: false) }
    }
}
