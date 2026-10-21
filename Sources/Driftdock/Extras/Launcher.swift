import SwiftUI
import AppKit

// MARK: - Safe calculator

/// Tiny arithmetic parser: + - * / % ^, parentheses, decimals. Never throws ObjC exceptions
/// the way NSExpression does on bad input.
enum Calculator {
    static func evaluate(_ text: String) -> Double? {
        let cleaned = text.replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: " ", with: "")
        guard !cleaned.isEmpty,
              cleaned.rangeOfCharacter(from: CharacterSet(charactersIn: "0123456789.+-*/%^()").inverted) == nil,
              cleaned.rangeOfCharacter(from: CharacterSet(charactersIn: "+-*/%^")) != nil
                || cleaned.contains("(") else { return nil }
        var parser = Parser(chars: Array(cleaned))
        guard let value = parser.expression(), parser.index == parser.chars.count, value.isFinite else { return nil }
        return value
    }

    private struct Parser {
        let chars: [Character]
        var index = 0

        mutating func peek() -> Character? { index < chars.count ? chars[index] : nil }

        mutating func expression() -> Double? {
            guard var value = term() else { return nil }
            while let c = peek(), c == "+" || c == "-" {
                index += 1
                guard let rhs = term() else { return nil }
                value = c == "+" ? value + rhs : value - rhs
            }
            return value
        }

        mutating func term() -> Double? {
            guard var value = power() else { return nil }
            while let c = peek(), c == "*" || c == "/" || c == "%" {
                index += 1
                guard let rhs = power() else { return nil }
                switch c {
                case "*": value *= rhs
                case "/": value /= rhs
                default: value = value.truncatingRemainder(dividingBy: rhs)
                }
            }
            return value
        }

        mutating func power() -> Double? {
            guard let base = unary() else { return nil }
            if peek() == "^" {
                index += 1
                guard let exp = power() else { return nil }
                return pow(base, exp)
            }
            return base
        }

        mutating func unary() -> Double? {
            if peek() == "-" { index += 1; return unary().map { -$0 } }
            if peek() == "+" { index += 1; return unary() }
            return primary()
        }

        mutating func primary() -> Double? {
            if peek() == "(" {
                index += 1
                let v = expression()
                guard peek() == ")" else { return nil }
                index += 1
                return v
            }
            let start = index
            while let c = peek(), c.isNumber || c == "." { index += 1 }
            guard index > start else { return nil }
            return Double(String(chars[start..<index]))
        }
    }

    static func format(_ v: Double) -> String {
        if v.rounded() == v && abs(v) < 1e15 { return String(Int64(v)) }
        let f = NumberFormatter()
        f.maximumFractionDigits = 8
        f.minimumFractionDigits = 0
        f.numberStyle = .decimal
        f.usesGroupingSeparator = false
        return f.string(from: NSNumber(value: v)) ?? String(v)
    }
}

// MARK: - Launcher

/// Thunderstorm-style search bar: apps, quick commands, math, and the web.
final class LauncherController {
    static let shared = LauncherController()
    private var panel: KeyPanel?

    func toggle() {
        if let panel, panel.isVisible { panel.dismiss(); return }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = NSHostingView(rootView: LauncherView(close: { [weak panel] in panel?.dismiss() },
                                                                 closeQuietly: { [weak panel] in panel?.dismiss(returnFocus: false) })
            .environmentObject(AppState.shared))
        panel.present()
    }

    private func makePanel() -> KeyPanel {
        KeyPanel(size: NSSize(width: 620, height: 380))
    }
}

struct LauncherCommand: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let run: () -> Void

    static var all: [LauncherCommand] {
        var list: [LauncherCommand] = [
            LauncherCommand(id: "awake", title: StayAwake.shared.isOn ? "Turn Off Stay Awake" : "Stay Awake",
                            symbol: "cup.and.saucer") { StayAwake.shared.toggle() },
            LauncherCommand(id: "clipboard", title: "Clipboard History", symbol: "doc.on.clipboard") {
                DispatchQueue.main.async { ClipboardPickerController.shared.toggle() }
            },
            LauncherCommand(id: "color", title: "Pick a Color from Screen", symbol: "eyedropper") { ScreenColorPicker.pick() },
            LauncherCommand(id: "dark", title: "Toggle Dark Mode", symbol: "circle.lefthalf.filled") {
                NowPlayingModel.run("tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode")
            },
            LauncherCommand(id: "focus", title: PomodoroModel.shared.running ? "Pause Focus Timer" : "Start Focus Timer",
                            symbol: "timer") { PomodoroModel.shared.toggle() },
            LauncherCommand(id: "shot", title: "Take a Screenshot", symbol: "camera.viewfinder") {
                NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Utilities/Screenshot.app"),
                                                   configuration: NSWorkspace.OpenConfiguration())
            },
            LauncherCommand(id: "tray", title: "Show File Tray", symbol: "tray.full") { FileTrayController.shared.show() },
            LauncherCommand(id: "dictate", title: VoiceTranscriber.shared.isRunning ? "Stop Dictation" : "Dictate into the Notch",
                            symbol: "waveform") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { VoiceTranscriber.shared.toggle() }
            },
            LauncherCommand(id: "stopwatch", title: "Start a Stopwatch", symbol: "stopwatch") {
                TimerCenter.shared.addStopwatch()
            },
            LauncherCommand(id: "mixer", title: "Volume Mixer", symbol: "slider.horizontal.3") {
                DispatchQueue.main.async { MixerPanelController.shared.toggle() }
            },
            LauncherCommand(id: "devices", title: "AirPods Battery", symbol: "airpods") {
                let devs = DevicesModel.shared.devices
                let parts: [String] = devs.map { d in
                    if let level = d.summary { return "\(d.name) \(level)%" }
                    return d.name
                }
                let text = devs.isEmpty ? "No devices connected" : parts.joined(separator: " · ")
                LiveActivityCenter.shared.flash(symbol: devs.first?.symbol ?? "airpods", text: text, seconds: 4)
                DevicesModel.shared.refresh()
            },
        ]
        let snaps: [LauncherCommand] = SnapTarget.allCases.map { target in
            // Runs after the launcher closes, so it moves the window you were using.
            LauncherCommand(id: "snap.\(target.rawValue)", title: "Window: \(target.title)", symbol: "macwindow") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { WindowSnapper.shared.snapFocused(target) }
            }
        }
        let tail: [LauncherCommand] = [
            LauncherCommand(id: "settings", title: "Driftdock Settings", symbol: "gearshape") {
                NotificationCenter.default.post(name: .driftdockOpenSettings, object: nil)
            },
            LauncherCommand(id: "restart", title: "Restart Driftdock", symbol: "arrow.clockwise") { AppRestarter.restart() },
        ]
        list += snaps
        list += tail
        return list
    }
}

private enum LauncherResult: Identifiable {
    case math(String)
    case app(URL)
    case command(LauncherCommand)
    case web(String)

    var id: String {
        switch self {
        case .math(let s): return "math:\(s)"
        case .app(let u): return "app:\(u.path)"
        case .command(let c): return "cmd:\(c.id)"
        case .web(let q): return "web:\(q)"
        }
    }
}

struct LauncherView: View {
    @EnvironmentObject var state: AppState
    let close: () -> Void
    let closeQuietly: () -> Void
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    private var results: [LauncherResult] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return LauncherCommand.all.prefix(5).map { .command($0) } }
        var out: [LauncherResult] = []
        if let secs = TimerCenter.parse(q), Calculator.evaluate(q) == nil {
            let label = TimerCenter.describe(secs)
            out.append(.command(LauncherCommand(id: "timer.\(Int(secs))", title: "Start a \(label) timer", symbol: "timer") {
                TimerCenter.shared.addTimer(secs)
            }))
        }
        if let v = Calculator.evaluate(q) { out.append(.math(Calculator.format(v))) }
        out += AppIndex.matches(q).prefix(5).map { .app($0) }
        out += LauncherCommand.all.filter { $0.title.localizedCaseInsensitiveContains(q) }.prefix(4).map { .command($0) }
        out.append(.web(q))
        return out
    }

    var body: some View {
        let items = results
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(state.accent)
                TextField("Search apps, run a command, or do math", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 22))
                    .focused($focused)
                    .onSubmit { run(items) }
                    .onChange(of: query) { _, _ in selection = 0 }
            }
            .padding(.horizontal, 18)
            .frame(height: 58)

            Divider().opacity(0.4)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                        row(item, selected: i == selection)
                            .onTapGesture { selection = i; run(items) }
                    }
                }
                .padding(8)
            }
        }
        .frame(width: 620, height: 380)
        .background(VisualEffect(material: .hudWindow, dark: true, radius: 16))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
        .environment(\.colorScheme, .dark)
        .onKeyPress(.downArrow) { selection = min(selection + 1, max(items.count - 1, 0)); return .handled }
        .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
        .onKeyPress(.escape) { close(); return .handled }
        .onAppear {
            query = ""
            selection = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = true }
        }
    }

    @ViewBuilder
    private func row(_ item: LauncherResult, selected: Bool) -> some View {
        HStack(spacing: 12) {
            switch item {
            case .math(let value):
                Image(systemName: "equal.circle.fill").font(.system(size: 20)).foregroundStyle(state.accent).frame(width: 28)
                Text(value).font(.system(size: 18, weight: .semibold, design: .rounded))
                Spacer()
                Text("Copy").font(.caption).foregroundStyle(.secondary)
            case .app(let url):
                Image(nsImage: IconCache.icon(for: url.path)).resizable().frame(width: 28, height: 28)
                Text(url.deletingPathExtension().lastPathComponent)
                Spacer()
                Text("App").font(.caption).foregroundStyle(.secondary)
            case .command(let c):
                Image(systemName: c.symbol).font(.system(size: 16)).frame(width: 28)
                Text(c.title)
                Spacer()
                Text("Command").font(.caption).foregroundStyle(.secondary)
            case .web(let q):
                Image(systemName: "globe").font(.system(size: 16)).frame(width: 28)
                Text("Search the web for “\(q)”").lineLimit(1)
                Spacer()
            }
        }
        .font(.system(size: 15))
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? state.accent.opacity(0.35) : Color.clear))
        .contentShape(Rectangle())
    }

    private func run(_ items: [LauncherResult]) {
        guard items.indices.contains(selection) else { return }
        switch items[selection] {
        case .math(let value):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            close()
        case .app(let url):
            closeQuietly()
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        case .command(let c):
            close()
            c.run()
        case .web(let q):
            closeQuietly()
            let base = state.config.searchEngine == "duckduckgo" ? "https://duckduckgo.com/?q=" : "https://www.google.com/search?q="
            if let url = URL(string: base + (q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q)) {
                NSWorkspace.shared.open(url)
            }
        }
    }
}

// MARK: - Color picker

enum ScreenColorPicker {
    /// The system eyedropper; the picked color's hex lands on the clipboard.
    static func pick() {
        NSColorSampler().show { color in
            guard let c = color?.usingColorSpace(.sRGB) else { return }
            let hex = String(format: "#%02X%02X%02X",
                             Int((c.redComponent * 255).rounded()),
                             Int((c.greenComponent * 255).rounded()),
                             Int((c.blueComponent * 255).rounded()))
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(hex, forType: .string)
            LiveActivityCenter.shared.flash(symbol: "eyedropper", text: "\(hex) copied")
        }
    }
}
