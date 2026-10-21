import AppKit

/// The Glide submenu under Driftdock's menu bar icon. Rebuilt each time it opens,
/// so the status line and Connect / Disconnect always match what's happening.
final class GlideMenu: NSObject, NSMenuDelegate {
    static let shared = GlideMenu()

    let menu = NSMenu(title: "Glide")

    private override init() {
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let glide = GlideController.shared
        let config = AppState.shared.config

        // Status line with a colored dot.
        let status = NSMenuItem(title: glide.status.text, action: nil, keyEquivalent: "")
        status.isEnabled = false
        status.image = Self.dot(glide.status.color)
        menu.addItem(status)

        if config.glideRole == "share", !config.glideHost.isEmpty {
            let peer = NSMenuItem(title: "Other computer: \(config.glideHost)", action: nil, keyEquivalent: "")
            peer.isEnabled = false
            menu.addItem(peer)
        } else if config.glideRole == "receive", let ip = GlideWire.localIPv4().first {
            let mine = NSMenuItem(title: "This Mac: \(ip)", action: nil, keyEquivalent: "")
            mine.isEnabled = false
            menu.addItem(mine)
        }
        menu.addItem(.separator())

        let shortcut = config.glideHotkey ? "  ⌃⌥⌘K" : ""
        if glide.isOn {
            add("Disconnect\(shortcut)", #selector(disconnect), symbol: "cable.connector.slash")
            add("Reconnect", #selector(reconnect), symbol: "arrow.clockwise")
        } else {
            add("Connect\(shortcut)", #selector(connect), symbol: "cable.connector")
        }
        if glide.isRemote {
            add("Bring Pointer Back  ⌃⌥⌘G", #selector(bringHome), symbol: "cursorarrow")
        }

        menu.addItem(.separator())
        let role = NSMenuItem(title: config.glideRole == "share" ? "This Mac has the mouse" : "The other computer has the mouse",
                              action: #selector(switchRole), keyEquivalent: "")
        role.target = self
        role.toolTip = "Click to switch which computer has the mouse"
        role.image = NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: nil)
        menu.addItem(role)
        add("Glide Settings…", #selector(openSettings), symbol: "gearshape")
    }

    private func add(_ title: String, _ action: Selector, symbol: String) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        menu.addItem(item)
    }

    private static func dot(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }

    @objc private func connect() { GlideController.shared.connect() }
    @objc private func disconnect() { GlideController.shared.disconnect() }
    @objc private func reconnect() { GlideController.shared.restart() }
    @objc private func bringHome() { GlideController.shared.bringHome() }

    @objc private func switchRole() {
        AppState.shared.config.glideRole = AppState.shared.config.glideRole == "share" ? "receive" : "share"
    }

    @objc private func openSettings() {
        NotificationCenter.default.post(name: .driftdockOpenSettings, object: nil)
    }
}
