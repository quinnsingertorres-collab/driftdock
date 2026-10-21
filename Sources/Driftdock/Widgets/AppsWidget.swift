import SwiftUI
import AppKit

// MARK: - Running apps

/// Tracks open apps (the ones that would show in the macOS Dock) and which is frontmost.
final class RunningApps: ObservableObject {
    static let shared = RunningApps()

    @Published private(set) var apps: [NSRunningApplication] = []
    @Published private(set) var paths: Set<String> = []
    @Published private(set) var frontmostPID: pid_t = 0

    private init() {
        refresh()
        let nc = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
        ]
        for name in names {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
        }
    }

    private func refresh() {
        let me = ProcessInfo.processInfo.processIdentifier
        let regular = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != me && $0.bundleURL != nil
        }
        apps = regular
        paths = Set(regular.compactMap { $0.bundleURL?.standardizedFileURL.path })
        frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
    }

    func app(atPath path: String) -> NSRunningApplication? {
        apps.first { $0.bundleURL?.standardizedFileURL.path == path }
    }
}

/// Dock-style click behavior shared by pinned and open app icons.
enum AppActions {
    static func click(_ app: NSRunningApplication, hideIfActive: Bool) {
        if hideIfActive && app.isActive && !app.isHidden {
            _ = app.hide()
            return
        }
        if app.isHidden { _ = app.unhide() }
        // Re-opening a running app activates it and, like the Dock, makes it
        // open a window if it has none.
        if let url = app.bundleURL {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        } else {
            _ = app.activate(options: [.activateAllWindows])
        }
    }
}

enum IconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(for path: String) -> NSImage {
        if let hit = cache[path] { return hit }
        let img = NSWorkspace.shared.icon(forFile: path)
        img.size = NSSize(width: 128, height: 128)
        cache[path] = img
        return img
    }
}

// MARK: - Widget

struct AppsWidget: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var running = RunningApps.shared
    @Environment(\.dockUnit) var u
    @Environment(\.dockEdge) var edge
    @State private var dropTargeted = false

    /// Open apps that aren't already pinned, in the chosen order.
    private var openApps: [NSRunningApplication] {
        guard state.config.showOpenApps else { return [] }
        let pinnedPaths = Set(state.config.pinned.map(\.path))
        let unpinned = running.apps.filter {
            guard let path = $0.bundleURL?.standardizedFileURL.path else { return false }
            return !pinnedPaths.contains(path)
        }
        if state.config.openAppsSort == "name" {
            return unpinned.sorted {
                ($0.localizedName ?? "").localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending
            }
        }
        return unpinned // launch order
    }

    var body: some View {
        let pinned = state.config.pinned
        let open = openApps
        let icon = u * 0.72
        let gap = u * 0.06
        let pad = u * 0.14
        let showDivider = state.config.showAppDivider && !pinned.isEmpty && !open.isEmpty
        let dividerWidth = u * 0.12
        let trash = state.config.showTrash

        Group {
            if edge.isHorizontal {
                let n = CGFloat(max(pinned.count + open.count + (trash ? 1 : 0), 1))
                let width = n * icon + (n - 1) * gap + (showDivider ? dividerWidth + gap : 0)
                    + (trash ? dividerWidth + gap : 0) + pad * 2
                Tile(span: width / u) {
                    HStack(spacing: gap) {
                        pinnedIcons(pinned, size: icon, placeholder: open.isEmpty)
                        if showDivider {
                            Capsule()
                                .fill(Color.primary.opacity(0.25))
                                .frame(width: 1.5, height: icon * 0.7)
                                .frame(width: dividerWidth)
                        }
                        openIcons(open, size: icon)
                        if trash {
                            Capsule()
                                .fill(Color.primary.opacity(0.25))
                                .frame(width: 1.5, height: icon * 0.7)
                                .frame(width: dividerWidth)
                            TrashIcon(size: icon)
                        }
                    }
                }
            } else {
                // Vertical docks: wrap icons into 3-column grids.
                let rowsP = rows(max(pinned.count, open.isEmpty ? 1 : 0))
                let rowsO = rows(open.count + (trash ? 1 : 0))
                let block: (CGFloat) -> CGFloat = { r in r > 0 ? r * icon + (r - 1) * gap : 0 }
                let between = (rowsP > 0 && rowsO > 0) ? gap * 2 + 1 : 0
                let height = block(rowsP) + block(rowsO) + between + pad * 2
                Tile(span: 3.3, rows: height / u) {
                    VStack(spacing: gap) {
                        if rowsP > 0 {
                            grid(size: icon, gap: gap) { pinnedIcons(pinned, size: icon, placeholder: open.isEmpty) }
                        }
                        if rowsP > 0 && rowsO > 0 {
                            Rectangle()
                                .fill(Color.primary.opacity(state.config.showAppDivider ? 0.25 : 0))
                                .frame(width: icon * 2.6, height: 1)
                        }
                        if rowsO > 0 {
                            grid(size: icon, gap: gap) {
                                openIcons(open, size: icon)
                                if trash { TrashIcon(size: icon) }
                            }
                        }
                    }
                }
            }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(state.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            state.addPinned(urls)
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    private func rows(_ count: Int) -> CGFloat {
        CGFloat(Int(ceil(Double(count) / 3.0)))
    }

    private func grid<C: View>(size: CGFloat, gap: CGFloat, @ViewBuilder _ content: () -> C) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(size), spacing: gap), count: 3), spacing: gap) {
            content()
        }
    }

    @ViewBuilder
    private func pinnedIcons(_ items: [PinnedItem], size: CGFloat, placeholder: Bool) -> some View {
        if items.isEmpty && placeholder {
            Image(systemName: "plus.app")
                .font(.system(size: size * 0.5))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
                .help("Drag apps or folders here")
        }
        ForEach(items) { item in
            PinnedIcon(item: item, size: size)
        }
    }

    @ViewBuilder
    private func openIcons(_ apps: [NSRunningApplication], size: CGFloat) -> some View {
        ForEach(apps, id: \.processIdentifier) { app in
            OpenAppIcon(app: app, size: size)
        }
    }
}

// MARK: - Icon chrome shared by pinned and open apps

struct DockIconChrome: ViewModifier {
    @Environment(\.dockEdge) var edge
    let hover: Bool
    let showDot: Bool
    let dimmed: Bool

    func body(content: Content) -> some View {
        content
            .opacity(dimmed ? 0.45 : 1)
            .scaleEffect(hover ? 1.16 : 1, anchor: anchor)
            .shadow(color: .black.opacity(hover ? 0.3 : 0), radius: 6, y: 3)
            .overlay(alignment: dotAlignment) {
                if showDot {
                    Circle()
                        .fill(Color.primary.opacity(0.75))
                        .frame(width: 4, height: 4)
                        .offset(dotOffset)
                }
            }
            .zIndex(hover ? 1 : 0)
    }

    private var anchor: UnitPoint {
        switch edge {
        case .bottom: return .bottom
        case .top: return .top
        case .left: return .leading
        case .right: return .trailing
        }
    }

    // The dot sits on the side facing the screen edge, like the macOS Dock.
    private var dotAlignment: Alignment {
        switch edge {
        case .bottom: return .bottom
        case .top: return .top
        case .left: return .leading
        case .right: return .trailing
        }
    }

    private var dotOffset: CGSize {
        switch edge {
        case .bottom: return CGSize(width: 0, height: 5)
        case .top: return CGSize(width: 0, height: -5)
        case .left: return CGSize(width: -5, height: 0)
        case .right: return CGSize(width: 5, height: 0)
        }
    }
}

// MARK: - Pinned icon

struct PinnedIcon: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var running = RunningApps.shared
    @Environment(\.dockEdge) var edge
    let item: PinnedItem
    let size: CGFloat
    @State private var hover = false
    @State private var showFolder = false

    private var url: URL { URL(fileURLWithPath: item.path) }
    private var isApp: Bool { item.path.hasSuffix(".app") }
    private var isFolder: Bool {
        var dir: ObjCBool = false
        return !isApp && FileManager.default.fileExists(atPath: item.path, isDirectory: &dir) && dir.boolValue
    }
    private var runningApp: NSRunningApplication? {
        isApp ? running.app(atPath: url.standardizedFileURL.path) : nil
    }

    var body: some View {
        let live = runningApp
        Button(action: open) {
            Image(nsImage: IconCache.icon(for: item.path))
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        .modifier(DockIconChrome(hover: hover,
                                 showDot: live != nil && state.config.showRunningDots,
                                 dimmed: (live?.isHidden ?? false) && state.config.dimHiddenApps))
        .onHover { h in
            withAnimation(.spring(response: 0.28, dampingFraction: 0.6)) { hover = h }
        }
        .help(url.deletingPathExtension().lastPathComponent)
        .popover(isPresented: $showFolder, arrowEdge: edge.popoverArrow) {
            FolderPopover(url: url).borrowsFocus()
        }
        .contextMenu {
            if let live {
                Button(live.isHidden ? "Show" : "Hide") {
                    _ = live.isHidden ? live.unhide() : live.hide()
                }
            }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Divider()
            Button("Remove from Dock") {
                state.config.pinned.removeAll { $0.id == item.id }
            }
            if let live {
                Divider()
                Button("Quit") { _ = live.terminate() }
            }
        }
    }

    private func open() {
        if let live = runningApp {
            AppActions.click(live, hideIfActive: state.config.clickActiveToHide)
        } else if isApp {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        } else if isFolder {
            showFolder.toggle()
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Open (unpinned) app icon

struct OpenAppIcon: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var running = RunningApps.shared
    let app: NSRunningApplication
    let size: CGFloat
    @State private var hover = false

    private var image: NSImage {
        if let path = app.bundleURL?.path { return IconCache.icon(for: path) }
        return app.icon ?? NSImage()
    }

    var body: some View {
        Button {
            AppActions.click(app, hideIfActive: state.config.clickActiveToHide)
        } label: {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        .modifier(DockIconChrome(hover: hover,
                                 showDot: state.config.showRunningDots,
                                 dimmed: app.isHidden && state.config.dimHiddenApps))
        .onHover { h in
            withAnimation(.spring(response: 0.28, dampingFraction: 0.6)) { hover = h }
        }
        .help(app.localizedName ?? "")
        .contextMenu {
            Button(app.isHidden ? "Show" : "Hide") {
                _ = app.isHidden ? app.unhide() : app.hide()
            }
            if let url = app.bundleURL {
                Button("Keep in Dock") { state.addPinned([url]) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            Divider()
            Button("Quit") { _ = app.terminate() }
        }
    }
}

// MARK: - Folder popover

/// A Stacks-style grid of a folder's newest items.
struct FolderPopover: View {
    let url: URL

    private var entries: [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let all = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys,
                                                                 options: [.skipsHiddenFiles])) ?? []
        return all.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
        .prefix(36)
        .map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(url.lastPathComponent).font(.headline)
                Spacer()
                Button("Open in Finder") { NSWorkspace.shared.open(url) }
                    .controlSize(.small)
            }
            let items = entries
            if items.isEmpty {
                Text("This folder is empty").foregroundStyle(.secondary).padding(.vertical, 20)
            } else {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(78), spacing: 8), count: 5), spacing: 12) {
                        ForEach(items, id: \.self) { item in
                            Button {
                                NSWorkspace.shared.open(item)
                            } label: {
                                VStack(spacing: 4) {
                                    Image(nsImage: IconCache.icon(for: item.path))
                                        .resizable()
                                        .frame(width: 44, height: 44)
                                    Text(item.lastPathComponent)
                                        .font(.system(size: 10))
                                        .lineLimit(2)
                                        .multilineTextAlignment(.center)
                                        .frame(width: 74)
                                }
                            }
                            .buttonStyle(.plain)
                            .help(item.lastPathComponent)
                        }
                    }
                }
                .frame(height: min(340, CGFloat((items.count + 4) / 5) * 86))
            }
        }
        .padding(14)
        .frame(width: 460)
    }
}

// MARK: - Trash

/// Watches whether the Trash has anything in it (for the full/empty icon).
final class TrashModel: ObservableObject {
    static let shared = TrashModel()
    @Published private(set) var isFull = false
    private var timer: Timer?
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")

    private init() {
        DispatchQueue.main.async { [weak self] in self?.check() }
        let t = Timer(timeInterval: 10, repeats: true) { [weak self] _ in self?.check() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func check() {
        // If macOS doesn't let us look inside, just show the empty icon.
        let items = (try? FileManager.default.contentsOfDirectory(atPath: Self.url.path)) ?? []
        let full = items.contains { !$0.hasPrefix(".") }
        if full != isFull { isFull = full }
    }

    func moveToTrash(_ urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        NSWorkspace.shared.recycle(files) { _, _ in
            DispatchQueue.main.async { self.check() }
        }
    }

    func empty() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Empty the Trash?"
        alert.informativeText = "Everything in the Trash will be deleted. You can't undo this."
        alert.addButton(withTitle: "Empty Trash")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        NowPlayingModel.run("tell application \"Finder\" to empty trash")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.check() }
    }
}

struct TrashIcon: View {
    @ObservedObject var trash = TrashModel.shared
    @Environment(\.dockEdge) var edge
    let size: CGFloat
    @State private var hover = false
    @State private var targeted = false

    var body: some View {
        Button {
            NSWorkspace.shared.open(TrashModel.url)
        } label: {
            Image(nsImage: NSImage(named: trash.isFull ? NSImage.trashFullName : NSImage.trashEmptyName) ?? NSImage())
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        .modifier(DockIconChrome(hover: hover || targeted, showDot: false, dimmed: false))
        .onHover { h in withAnimation(.spring(response: 0.28, dampingFraction: 0.6)) { hover = h } }
        .dropDestination(for: URL.self) { urls, _ in
            trash.moveToTrash(urls)
            return true
        } isTargeted: { t in withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) { targeted = t } }
        .help("Trash. Drop files here to move them to the Trash")
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(TrashModel.url) }
            Divider()
            Button("Empty Trash…") { trash.empty() }
        }
    }
}
