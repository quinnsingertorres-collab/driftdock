import SwiftUI
import AppKit

// MARK: - To-dos

struct TodoItem: Codable, Identifiable, Hashable {
    var id = UUID()
    var text: String
    var done = false
}

final class TodoStore: ObservableObject {
    static let shared = TodoStore()
    private let key = "driftdock.todos.v1"

    @Published var items: [TodoItem] {
        didSet {
            if let data = try? JSONEncoder().encode(items) {
                UserDefaults.standard.set(data, forKey: key)
            }
        }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([TodoItem].self, from: data) {
            items = saved
        } else {
            items = []
        }
    }

    var remaining: [TodoItem] { items.filter { !$0.done } }

    func add(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        items.append(TodoItem(text: t))
    }
}

struct TodoWidget: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var store = TodoStore.shared
    @Environment(\.dockUnit) var u
    @Environment(\.dockEdge) var edge
    @State private var open = false

    var body: some View {
        let left = store.remaining
        Tile(span: 2.4) {
            Button { open.toggle() } label: {
                HStack(spacing: u * 0.12) {
                    ZStack {
                        Circle().fill(state.accent.opacity(0.22))
                        Image(systemName: left.isEmpty ? "checkmark" : "checklist")
                            .font(.system(size: u * 0.2, weight: .semibold))
                            .foregroundStyle(state.accent)
                    }
                    .frame(width: u * 0.46, height: u * 0.46)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(left.isEmpty ? "All clear" : "\(left.count) to do")
                            .font(.system(size: u * 0.16, weight: .semibold))
                        Text(left.first?.text ?? "Click to add a task")
                            .font(.system(size: u * 0.13))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, u * 0.14)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .popover(isPresented: $open, arrowEdge: edge.popoverArrow) {
            TodoPopover(store: store).borrowsFocus()
        }
    }
}

struct TodoPopover: View {
    @ObservedObject var store: TodoStore
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("To-dos").font(.headline)
                Spacer()
                if store.items.contains(where: \.done) {
                    Button("Clear done") { store.items.removeAll(where: \.done) }
                        .controlSize(.small)
                }
            }
            TextField("Add a to-do and press Return", text: $draft)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit {
                    store.add(draft)
                    draft = ""
                }
            if store.items.isEmpty {
                Text("Nothing here yet.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(store.items) { item in
                            TodoRow(item: binding(for: item)) {
                                store.items.removeAll { $0.id == item.id }
                            }
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
        }
        .padding(14)
        .frame(width: 320)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { focused = true }
        }
    }

    /// Look items up by id so deleting a row never indexes past the end of the array.
    private func binding(for item: TodoItem) -> Binding<TodoItem> {
        Binding(
            get: { store.items.first(where: { $0.id == item.id }) ?? item },
            set: { updated in
                if let i = store.items.firstIndex(where: { $0.id == item.id }) {
                    store.items[i] = updated
                }
            }
        )
    }
}

struct TodoRow: View {
    @Binding var item: TodoItem
    var onDelete: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { item.done.toggle() }
            } label: {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(item.done ? AppState.shared.accent : Color.secondary)
            }
            .buttonStyle(.plain)
            Text(item.text)
                .strikethrough(item.done)
                .foregroundStyle(item.done ? .secondary : .primary)
                .lineLimit(2)
            Spacer()
            if hover {
                Button(action: onDelete) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hover ? 0.06 : 0)))
        .onHover { hover = $0 }
    }
}

// MARK: - Focus timer

final class PomodoroModel: ObservableObject {
    static let shared = PomodoroModel()

    enum Phase { case focus, rest }

    @Published var phase: Phase = .focus
    @Published var remaining: TimeInterval = 25 * 60
    @Published var running = false

    let focusLength: TimeInterval = 25 * 60
    let restLength: TimeInterval = 5 * 60

    private var endDate: Date?
    private var timer: Timer?

    var total: TimeInterval { phase == .focus ? focusLength : restLength }
    var progress: Double { 1 - remaining / total }

    func toggle() { running ? pause() : start() }

    func start() {
        endDate = Date().addingTimeInterval(remaining)
        running = true
        timer?.invalidate()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func pause() {
        if let end = endDate { remaining = max(0, end.timeIntervalSinceNow) }
        running = false
        timer?.invalidate()
        timer = nil
        endDate = nil
    }

    func reset() {
        pause()
        remaining = total
    }

    func skip() {
        pause()
        phase = phase == .focus ? .rest : .focus
        remaining = total
    }

    private func tick() {
        guard let end = endDate else { return }
        remaining = max(0, end.timeIntervalSinceNow)
        if remaining <= 0 {
            NSSound(named: NSSound.Name("Glass"))?.play()
            let wasFocus = phase == .focus
            LiveActivityCenter.shared.showBanner(.init(
                symbol: wasFocus ? "cup.and.saucer.fill" : "brain.head.profile", tint: .orange,
                title: wasFocus ? "Focus done" : "Break's over",
                subtitle: wasFocus ? "Take a \(Int(restLength / 60))-minute break." : "Ready for the next focus session?",
                trailing: nil))
            skip()
        }
    }
}

struct PomodoroWidget: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var model = PomodoroModel.shared
    @Environment(\.dockUnit) var u

    var body: some View {
        let mins = Int(model.remaining) / 60
        let secs = Int(model.remaining) % 60
        let tint: Color = model.phase == .focus ? state.accent : .green
        Tile(span: 2.2) {
            HStack(spacing: u * 0.12) {
                ZStack {
                    Circle().stroke(Color.primary.opacity(0.12), lineWidth: u * 0.055)
                    Circle()
                        .trim(from: 0, to: max(0.001, model.progress))
                        .stroke(tint, style: StrokeStyle(lineWidth: u * 0.055, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: model.phase == .focus ? "brain.head.profile" : "cup.and.saucer.fill")
                        .font(.system(size: u * 0.16))
                        .foregroundStyle(tint)
                }
                .frame(width: u * 0.5, height: u * 0.5)

                VStack(alignment: .leading, spacing: 0) {
                    Text(String(format: "%02d:%02d", mins, secs))
                        .font(.system(size: u * 0.22, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    HStack(spacing: 0) {
                        DockIconButton(symbol: model.running ? "pause.fill" : "play.fill", size: 0.14,
                                       help: model.running ? "Pause" : "Start", action: model.toggle)
                        DockIconButton(symbol: "arrow.counterclockwise", size: 0.13, help: "Reset", action: model.reset)
                        DockIconButton(symbol: "forward.end.fill", size: 0.13, help: "Skip", action: model.skip)
                    }
                    .padding(.leading, -u * 0.05)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, u * 0.14)
        }
    }
}

// MARK: - Clipboard history

// ClipboardModel lives in Extras/ClipboardManager.swift.

struct ClipboardWidget: View {
    @ObservedObject var model = ClipboardModel.shared
    @Environment(\.dockUnit) var u
    @Environment(\.dockEdge) var edge
    @State private var open = false

    var body: some View {
        Tile(span: 2.3) {
            Button { open.toggle() } label: {
                HStack(spacing: u * 0.12) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: u * 0.22))
                        .foregroundStyle(.secondary)
                        .frame(width: u * 0.4)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Clipboard")
                            .font(.system(size: u * 0.15, weight: .semibold))
                        Text(model.history.first.map(Self.oneLine) ?? "Copied text shows up here")
                            .font(.system(size: u * 0.12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, u * 0.14)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .popover(isPresented: $open, arrowEdge: edge.popoverArrow) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Clipboard history").font(.headline)
                    Spacer()
                    if !model.history.isEmpty {
                        Button("Clear") { model.clearUnpinned() }.controlSize(.small)
                    }
                }
                if model.history.isEmpty {
                    Text("Copy some text and it will appear here.")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(model.history, id: \.self) { s in
                                ClipRow(text: Self.oneLine(s)) {
                                    model.copy(s)
                                    open = false
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 300)
                }
                Text("Click an item to copy it again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(width: 340)
            .borrowsFocus()
        }
    }

    static func oneLine(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
    }
}

struct ClipRow: View {
    let text: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(text)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hover ? 0.08 : 0.03)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: - Search

enum AppIndex {
    private static var cached: [URL]?
    private static var cachedAt = Date.distantPast

    static var apps: [URL] {
        if let cached, Date().timeIntervalSince(cachedAt) < 300 { return cached }
        cachedAt = Date()
        let fm = FileManager.default
        let roots = ["/Applications", "/Applications/Utilities", "/System/Applications",
                     "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"]
        var found: [URL] = [URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")]
        for root in roots {
            let items = (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: root), includingPropertiesForKeys: nil,
                                                     options: [.skipsHiddenFiles])) ?? []
            found += items.filter { $0.pathExtension == "app" }
        }
        cached = found
        return found
    }

    static func matches(_ query: String) -> [URL] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let named = apps.map { ($0, $0.deletingPathExtension().lastPathComponent.lowercased()) }
        let prefix = named.filter { $0.1.hasPrefix(q) }.map(\.0)
        let contains = named.filter { !$0.1.hasPrefix(q) && $0.1.contains(q) }.map(\.0)
        return Array((prefix + contains).prefix(6))
    }
}

struct SearchWidget: View {
    @Environment(\.dockUnit) var u
    @Environment(\.dockEdge) var edge
    @State private var open = false

    var body: some View {
        Tile(span: 1) {
            Button { open.toggle() } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: u * 0.3, weight: .semibold))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Search apps and the web")
        }
        .popover(isPresented: $open, arrowEdge: edge.popoverArrow) {
            SearchPopover(close: { open = false })
                .environmentObject(AppState.shared)
                .borrowsFocus()
        }
    }
}

struct SearchPopover: View {
    @EnvironmentObject var state: AppState
    var close: () -> Void
    @State private var query = ""
    @FocusState private var focused: Bool

    var body: some View {
        let results = AppIndex.matches(query)
        VStack(alignment: .leading, spacing: 8) {
            TextField("Open an app or search the web", text: $query)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 15))
                .focused($focused)
                .onSubmit { submit(results) }

            ForEach(results, id: \.self) { url in
                Button {
                    launch(url)
                } label: {
                    HStack(spacing: 8) {
                        Image(nsImage: IconCache.icon(for: url.path)).resizable().frame(width: 22, height: 22)
                        Text(url.deletingPathExtension().lastPathComponent)
                        Spacer()
                        if url == results.first {
                            Text("↩").foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                Button {
                    searchWeb()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "globe").frame(width: 22)
                        Text("Search the web for “\(query)”").lineLimit(1)
                        Spacer()
                        if results.isEmpty { Text("↩").foregroundStyle(.secondary) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: 340)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { focused = true }
        }
    }

    private func submit(_ results: [URL]) {
        if let first = results.first { launch(first) } else { searchWeb() }
    }

    private func launch(_ url: URL) {
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        query = ""
        close()
    }

    private func searchWeb() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        if q.contains("."), !q.contains(" "), let url = URL(string: q.hasPrefix("http") ? q : "https://\(q)") {
            NSWorkspace.shared.open(url)
        } else {
            let base = state.config.searchEngine == "duckduckgo"
                ? "https://duckduckgo.com/?q=" : "https://www.google.com/search?q="
            let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
            if let url = URL(string: base + encoded) { NSWorkspace.shared.open(url) }
        }
        query = ""
        close()
    }
}

// MARK: - Quick toggles

struct TogglesWidget: View {
    @Environment(\.dockUnit) var u

    var body: some View {
        Tile(span: 1.5) {
            Grid(horizontalSpacing: u * 0.04, verticalSpacing: u * 0.02) {
                GridRow {
                    DockIconButton(symbol: "circle.lefthalf.filled", size: 0.17, help: "Toggle dark mode") {
                        NowPlayingModel.run("""
                        tell application "System Events" to tell appearance preferences to set dark mode to not dark mode
                        """)
                    }
                    DockIconButton(symbol: "speaker.slash.fill", size: 0.17, help: "Mute / unmute") {
                        NowPlayingModel.run("set volume output muted (not (output muted of (get volume settings)))")
                    }
                }
                GridRow {
                    DockIconButton(symbol: "camera.viewfinder", size: 0.17, help: "Screenshot") {
                        NSWorkspace.shared.openApplication(
                            at: URL(fileURLWithPath: "/System/Applications/Utilities/Screenshot.app"),
                            configuration: NSWorkspace.OpenConfiguration())
                    }
                    DockIconButton(symbol: "display", size: 0.17, help: "Sleep display") {
                        let p = Process()
                        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
                        p.arguments = ["displaysleepnow"]
                        try? p.run()
                    }
                }
            }
        }
    }
}
