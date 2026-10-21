import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Reads Music and Spotify through AppleScript. macOS asks once per app for Automation permission.
final class NowPlayingModel: ObservableObject {
    static let shared = NowPlayingModel()

    @Published var title = ""
    @Published var artist = ""
    @Published var isPlaying = false
    @Published var artwork: NSImage?
    @Published var player: String?          // "Music" or "Spotify"
    /// Seconds into the track when we last asked, and when that was (for smooth progress).
    // Not @Published: these change every poll, and the progress bar reads them on its own timer.
    // Publishing them made the whole dock and notch redraw every couple of seconds.
    var position: Double = 0
    var positionDate = Date()
    @Published var duration: Double = 0

    private var timer: Timer?
    private var lastTrackKey = ""

    private let players: [(bundleID: String, name: String)] = [
        ("com.spotify.client", "Spotify"),
        ("com.apple.Music", "Music"),
    ]

    private init() {
        // Never run AppleScript inside init: it spins the run loop, SwiftUI re-renders,
        // and touches `shared` again while it's still being created (launch crash).
        DispatchQueue.main.async { [weak self] in self?.poll() }
        let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in self?.poll() }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
        // Music and Spotify announce track and play/pause changes; react instantly to those.
        let dnc = DistributedNotificationCenter.default()
        for name in ["com.apple.Music.playerInfo", "com.spotify.client.PlaybackStateChanged"] {
            dnc.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                self?.poll()
            }
        }
    }

    func poll() {
        let runningIDs = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        var paused: (String, [String])?

        // Only talk to players that are already open, so we never launch one by accident.
        for p in players where runningIDs.contains(p.bundleID) {
            let script = """
            tell application "\(p.name)"
                if player state is playing or player state is paused then
                    set t to current track
                    return (name of t) & "\\n" & (artist of t) & "\\n" & (player state as string) & "\\n" & (player position as string) & "\\n" & (duration of t as string)
                end if
            end tell
            return ""
            """
            guard let out = Self.run(script)?.stringValue, !out.isEmpty else { continue }
            let parts = out.components(separatedBy: "\n")
            guard parts.count >= 3 else { continue }
            if parts[2] == "playing" {
                apply(player: p.name, parts: parts)
                return
            } else if paused == nil {
                paused = (p.name, parts)
            }
        }

        if case let (name, parts)? = paused {
            apply(player: name, parts: parts)
        } else if player != nil {
            player = nil
            title = ""
            artist = ""
            isPlaying = false
            artwork = nil
            duration = 0
            lastTrackKey = ""
        }
    }

    private func apply(player name: String, parts: [String]) {
        // Assign only real changes: every @Published write redraws everything watching it.
        if player != name { player = name }
        if title != parts[0] { title = parts[0] }
        if artist != parts[1] { artist = parts[1] }
        let playing = parts[2] == "playing"
        if isPlaying != playing { isPlaying = playing }
        if parts.count >= 5 {
            // Reals can come back with a decimal comma depending on region.
            let pos = Double(parts[3].replacingOccurrences(of: ",", with: ".")) ?? 0
            var dur = Double(parts[4].replacingOccurrences(of: ",", with: ".")) ?? 0
            if name == "Spotify" { dur /= 1000 } // Spotify reports milliseconds
            position = pos
            positionDate = Date()
            if abs(duration - dur) > 0.5 { duration = dur }
        }
        let key = "\(name)|\(parts[0])|\(parts[1])"
        if key != lastTrackKey {
            lastTrackKey = key
            loadArtwork(for: name)
        }
    }

    private func loadArtwork(for name: String) {
        artwork = nil
        if name == "Spotify" {
            let src = "tell application \"Spotify\" to return artwork url of current track"
            guard let s = Self.run(src)?.stringValue, let url = URL(string: s) else { return }
            URLSession.shared.dataTask(with: url) { data, _, _ in
                guard let data, let img = NSImage(data: data) else { return }
                DispatchQueue.main.async { self.artwork = img }
            }.resume()
        } else {
            let src = """
            tell application "Music"
                try
                    return raw data of artwork 1 of current track
                end try
            end tell
            """
            if let data = Self.run(src)?.data, let img = NSImage(data: data) {
                artwork = img
            }
        }
    }

    /// The app chosen in Settings → Widgets → Now Playing for when nothing is playing.
    static var idleAppID: String { AppState.shared.config.idleMusicApp }

    static var idleAppName: String {
        switch idleAppID {
        case "com.apple.Music": return "Music"
        case "com.spotify.client": return "Spotify"
        default:
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: idleAppID) else { return "Music" }
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
    }

    /// AppleScript name, only for players Driftdock can control.
    private static var idleScriptName: String? {
        switch idleAppID {
        case "com.apple.Music": return "Music"
        case "com.spotify.client": return "Spotify"
        default: return nil
        }
    }

    func command(_ verb: String) {
        guard let name = player else {
            // Nothing playing: Play starts your chosen player; anything else just opens it.
            if verb == "playpause", let script = Self.idleScriptName {
                Self.run("tell application \"\(script)\" to play")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.poll() }
            } else {
                openPlayer()
            }
            return
        }
        Self.run("tell application \"\(name)\" to \(verb)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.poll() }
    }

    /// Where playback is right now, estimated between polls.
    func currentPosition(at date: Date = Date()) -> Double {
        let p = isPlaying ? position + date.timeIntervalSince(positionDate) : position
        return duration > 0 ? min(max(0, p), duration) : max(0, p)
    }

    func seek(to fraction: Double) {
        guard let name = player, duration > 0 else { return }
        let target = max(0, min(1, fraction)) * duration
        Self.run("tell application \"\(name)\" to set player position to \(String(format: "%.2f", target))")
        position = target
        positionDate = Date()
    }

    func openPlayer() {
        let id: String
        switch player {
        case "Spotify": id = "com.spotify.client"
        case "Music": id = "com.apple.Music"
        default: id = Self.idleAppID
        }
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            ?? URL(fileURLWithPath: "/System/Applications/Music.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    @discardableResult
    static func run(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil ? result : nil
    }
}

struct NowPlayingWidget: View {
    @ObservedObject var model = NowPlayingModel.shared
    @Environment(\.dockUnit) var u

    var body: some View {
        Tile(span: 3.0) {
            HStack(spacing: u * 0.12) {
                Button(action: model.openPlayer) {
                    ZStack {
                        RoundedRectangle(cornerRadius: u * 0.12, style: .continuous)
                            .fill(Color.primary.opacity(0.1))
                        if let art = model.artwork {
                            Image(nsImage: art).resizable().scaledToFill()
                        } else {
                            Image(systemName: "music.note")
                                .font(.system(size: u * 0.26))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: u * 0.72, height: u * 0.72)
                    .clipShape(RoundedRectangle(cornerRadius: u * 0.12, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("Open \(model.player ?? NowPlayingModel.idleAppName)")

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.title.isEmpty ? "Not playing" : model.title)
                        .font(.system(size: u * 0.16, weight: .semibold))
                        .lineLimit(1)
                    Text(model.artist.isEmpty ? "Click to open \(NowPlayingModel.idleAppName)" : model.artist)
                        .font(.system(size: u * 0.13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    HStack(spacing: u * 0.04) {
                        DockIconButton(symbol: "backward.fill", size: 0.16, help: "Previous") { model.command("previous track") }
                        DockIconButton(symbol: model.isPlaying ? "pause.fill" : "play.fill", size: 0.2, help: "Play/Pause") {
                            model.command("playpause")
                        }
                        DockIconButton(symbol: "forward.fill", size: 0.16, help: "Next") { model.command("next track") }
                    }
                    .padding(.leading, -u * 0.06)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, u * 0.14)
        }
        .contextMenu { IdlePlayerMenu() }
    }
}

/// "When nothing is playing, open…" choices, shared by the dock and Settings.
struct IdlePlayerMenu: View {
    @ObservedObject var state = AppState.shared

    var body: some View {
        Menu("When Nothing Is Playing, Open") {
            Picker("", selection: $state.config.idleMusicApp) {
                Text("Music").tag("com.apple.Music")
                Text("Spotify").tag("com.spotify.client")
                if !["com.apple.Music", "com.spotify.client"].contains(state.config.idleMusicApp) {
                    Text(NowPlayingModel.idleAppName).tag(state.config.idleMusicApp)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Button("Other App…") { Self.chooseApp() }
        }
        Toggle("Hide When Nothing Is Playing", isOn: $state.config.hideIdleMusic)
    }

    static func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Choose"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier {
            AppState.shared.config.idleMusicApp = id
        }
    }
}
