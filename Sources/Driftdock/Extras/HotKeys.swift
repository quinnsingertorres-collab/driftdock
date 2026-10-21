import AppKit
import Carbon.HIToolbox

/// System-wide keyboard shortcuts via Carbon hot keys (no Accessibility permission needed).
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var installed = false

    private init() {}

    /// Registers (or replaces) a shortcut. `modifiers` uses Carbon flags like `optionKey`.
    func register(id: UInt32, keyCode: Int, modifiers: Int, handler: @escaping () -> Void) {
        installIfNeeded()
        unregister(id: id)
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4452_4654), id: id) // "DRFT"
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            refs[id] = ref
            handlers[id] = handler
        }
    }

    func unregister(id: UInt32) {
        if let ref = refs[id] { UnregisterEventHotKey(ref) }
        refs[id] = nil
        handlers[id] = nil
    }

    fileprivate func fire(_ id: UInt32) {
        handlers[id]?()
    }

    private func installIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            DispatchQueue.main.async { HotKeyCenter.shared.fire(id) }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

/// A borderless panel that can take keyboard focus, for the launcher and clipboard picker.
final class KeyPanel: NSPanel, NSWindowDelegate {
    var onClose: (() -> Void)?

    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .modalPanel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
        delegate = self
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Shows the panel centered in the upper third of the screen the pointer is on.
    func present() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.screens.first
        if let vf = screen?.visibleFrame {
            setFrameOrigin(NSPoint(x: vf.midX - frame.width / 2, y: vf.maxY - vf.height * 0.28 - frame.height))
        }
        FocusBroker.borrow()
        makeKeyAndOrderFront(nil)
    }

    func dismiss(returnFocus: Bool = true) {
        orderOut(nil)
        if returnFocus { FocusBroker.giveBack() }
        onClose?()
    }

    // Click anywhere else and it goes away, like Spotlight.
    func windowDidResignKey(_ notification: Notification) {
        if isVisible { dismiss(returnFocus: false) }
    }

    override func cancelOperation(_ sender: Any?) {
        dismiss()
    }
}
