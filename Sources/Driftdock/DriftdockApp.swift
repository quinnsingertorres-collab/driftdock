import SwiftUI
import AppKit

@main
struct DriftdockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // The dock lives in its own panel; this empty scene just keeps SwiftUI happy.
        Settings { EmptyView() }
    }
}

/// Quits Driftdock and starts it again once the old copy has fully exited.
enum AppRestarter {
    /// Set while restarting, so quitting doesn't flash the system Dock back in.
    static var isRestarting = false

    static func restart() {
        isRestarting = true
        let pid = ProcessInfo.processInfo.processIdentifier
        let path = Bundle.main.bundlePath
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Wait for this process to exit (up to ~10s), then reopen the app.
        helper.arguments = ["-c", "for i in $(seq 1 100); do kill -0 \(pid) 2>/dev/null || break; sleep 0.1; done; kill -9 \(pid) 2>/dev/null; open \"$1\"", "sh", path]
        do {
            try helper.run()
        } catch {
            isRestarting = false
            NSSound.beep()
            return
        }
        NSApp.terminate(nil)
        // If anything blocks a normal quit, force it after a moment.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { exit(0) }
    }
}

extension Notification.Name {
    static let driftdockOpenSettings = Notification.Name("driftdock.openSettings")
    static let driftdockToggleDock = Notification.Name("driftdock.toggleDock")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var docks: DockManager?
    private var notch: NotchController?
    private var extras: ExtrasController?
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if AppState.shared.config.replaceSystemDock { SystemDock.hide() }

        docks = DockManager(state: AppState.shared)   // builds the dock(s) right away
        notch = NotchController(state: AppState.shared)
        extras = ExtrasController(state: AppState.shared)
        GlideController.shared.bind(AppState.shared)

        buildStatusItem()

        NotificationCenter.default.addObserver(self, selector: #selector(openSettings),
                                               name: .driftdockOpenSettings, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(toggleDock),
                                               name: .driftdockToggleDock, object: nil)
    }

    // Never leave someone without a Dock: put the system one back whenever we quit.
    func applicationWillTerminate(_ notification: Notification) {
        if AppState.shared.config.replaceSystemDock && !AppRestarter.isRestarting { SystemDock.restore() }
    }

    // Double-clicking the app again opens Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return true
    }

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "dock.rectangle", accessibilityDescription: "Driftdock")

        let menu = NSMenu()
        menu.addItem(withTitle: "Show / Hide Dock", action: #selector(toggleDock), keyEquivalent: "d").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Launcher (⌥Space)", action: #selector(openLauncher), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Clipboard History (⇧⌘V)", action: #selector(openClipboard), keyEquivalent: "").target = self
        menu.addItem(withTitle: "File Tray", action: #selector(openTray), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Volume Mixer", action: #selector(openMixer), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Glide (Mouse Sharing) On / Off", action: #selector(toggleGlide), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Restart Driftdock", action: #selector(restart), keyEquivalent: "r").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Driftdock", action: #selector(quit), keyEquivalent: "q").target = self
        item.menu = menu
        statusItem = item
    }

    @objc func toggleDock() {
        docks?.toggleVisibility()
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView().environmentObject(AppState.shared))
            let window = NSWindow(contentViewController: host)
            window.title = "Driftdock Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 640, height: 640))
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func openLauncher() { LauncherController.shared.toggle() }
    @objc func openClipboard() { ClipboardPickerController.shared.toggle() }
    @objc func openTray() { FileTrayController.shared.show() }
    @objc func openMixer() { MixerPanelController.shared.toggle() }
    @objc func toggleGlide() {
        AppState.shared.config.glideEnabled.toggle()
        LiveActivityCenter.shared.flash(symbol: "cursorarrow.motionlines",
                                        text: AppState.shared.config.glideEnabled ? "Glide on" : "Glide off")
    }

    @objc func restart() {
        AppRestarter.restart()
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }
}
