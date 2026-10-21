import Foundation

/// Hides the macOS Dock by turning on its auto-hide with a very long reveal delay,
/// so it never slides up. Your original settings are saved and put back on restore.
///
/// If Driftdock ever crashes while this is on, run this in Terminal to get the Dock back:
///   defaults delete com.apple.dock autohide-delay; killall Dock
enum SystemDock {
    private static let savedKey = "driftdock.savedSystemDock"
    private static let hiddenDelay = "1000"

    static var isHidden: Bool {
        read("autohide") == "1" && (Double(read("autohide-delay") ?? "") ?? 0) >= 100
    }

    static func hide() {
        guard !isHidden else { return }
        UserDefaults.standard.set([
            "autohide": read("autohide") ?? "0",
            "delay": read("autohide-delay") ?? "",
        ], forKey: savedKey)
        run("/usr/bin/defaults", ["write", "com.apple.dock", "autohide", "-bool", "true"])
        run("/usr/bin/defaults", ["write", "com.apple.dock", "autohide-delay", "-float", hiddenDelay])
        run("/usr/bin/killall", ["Dock"])
    }

    static func restore() {
        guard isHidden else { return }
        let saved = UserDefaults.standard.dictionary(forKey: savedKey) as? [String: String]
        let autohide = saved?["autohide"] == "1"
        run("/usr/bin/defaults", ["write", "com.apple.dock", "autohide", "-bool", autohide ? "true" : "false"])
        if let delay = saved?["delay"], !delay.isEmpty, (Double(delay) ?? 0) < 100 {
            run("/usr/bin/defaults", ["write", "com.apple.dock", "autohide-delay", "-float", delay])
        } else {
            run("/usr/bin/defaults", ["delete", "com.apple.dock", "autohide-delay"])
        }
        run("/usr/bin/killall", ["Dock"])
    }

    private static func read(_ key: String) -> String? {
        run("/usr/bin/defaults", ["read", "com.apple.dock", key])
    }

    @discardableResult
    private static func run(_ tool: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        // Read to EOF first; waitUntilExit alone would spin the run loop mid-update.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
