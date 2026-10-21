import SwiftUI
import AppKit
import QuickLookThumbnailing

extension Notification.Name {
    /// Posted when a new screenshot shows up, so an auto-hidden dock can pop up.
    static let driftdockNewScreenshot = Notification.Name("driftdock.newScreenshot")
}

/// Watches the screenshot folder and keeps the ones taken in the last few minutes.
final class ScreenshotModel: ObservableObject {
    static let shared = ScreenshotModel()

    struct Shot: Identifiable, Equatable {
        let url: URL
        let created: Date
        var id: URL { url }
        var isVideo: Bool { ["mov", "mp4"].contains(url.pathExtension.lowercased()) }
    }

    @Published private(set) var shots: [Shot] = []
    @Published private(set) var thumbnails: [URL: NSImage] = [:]

    private var dismissed = Set<URL>()
    private var known = Set<URL>()
    private var firstScan = true
    private var timer: Timer?

    private init() {
        // First scan after setup, never during it (see the Now Playing launch crash).
        DispatchQueue.main.async { [weak self] in
            self?.watchFolder()
            self?.scan()
        }
        // Slow timer only to age screenshots off the dock (and notice a changed save folder).
        let t = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            self?.watchFolder()
            self?.scan()
        }
        t.tolerance = 3
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private var watcher: DispatchSourceFileSystemObject?
    private var watchedPath = ""

    /// Rescan the moment something is added to the screenshot folder.
    private func watchFolder() {
        let path = Self.folder.path
        guard path != watchedPath else { return }
        watcher?.cancel()
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            // Screenshots land a moment after the folder changes; scan twice.
            self?.scan()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self?.scan() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
        watchedPath = path
    }

    /// Where macOS saves screenshots (Screenshot app → Options → Save to), Desktop by default.
    static var folder: URL {
        if let path = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"),
           !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }

    func scan() {
        let cfg = AppState.shared.config
        let cutoff = Date().addingTimeInterval(-cfg.screenshotMinutes * 60)
        var exts: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "pdf"]
        if cfg.includeRecordings { exts.formUnion(["mov", "mp4"]) }

        let keys: [URLResourceKey] = [.creationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.folder,
                                                                   includingPropertiesForKeys: keys,
                                                                   options: [.skipsHiddenFiles])) ?? []
        var fresh: [Shot] = []
        for file in files where exts.contains(file.pathExtension.lowercased()) {
            guard let created = try? file.resourceValues(forKeys: [.creationDateKey]).creationDate,
                  created >= cutoff,
                  !dismissed.contains(file),
                  Self.isScreenCapture(file) else { continue }
            fresh.append(Shot(url: file, created: created))
        }
        fresh.sort { $0.created > $1.created }

        let newOnes = fresh.filter { !known.contains($0.url) }
        known.formUnion(newOnes.map(\.url))
        if !newOnes.isEmpty && !firstScan {
            NotificationCenter.default.post(name: .driftdockNewScreenshot, object: nil)
        }
        firstScan = false

        if fresh != shots { shots = fresh }

        // Forget anything that has aged out.
        let live = Set(fresh.map(\.url))
        let present = Set(files)
        dismissed = dismissed.filter { present.contains($0) }
        if thumbnails.keys.contains(where: { !live.contains($0) }) {
            thumbnails = thumbnails.filter { live.contains($0.key) }
        }
        for shot in fresh where thumbnails[shot.url] == nil {
            makeThumbnail(for: shot.url)
        }
    }

    /// macOS tags its screenshots and screen recordings with this attribute.
    static func isScreenCapture(_ url: URL) -> Bool {
        getxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0) > 0
    }

    private var pendingThumbs = Set<URL>()

    private func makeThumbnail(for url: URL) {
        guard !pendingThumbs.contains(url) else { return }
        pendingThumbs.insert(url)
        let request = QLThumbnailGenerator.Request(fileAt: url,
                                                   size: CGSize(width: 480, height: 320),
                                                   scale: 2,
                                                   representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            DispatchQueue.main.async {
                self?.pendingThumbs.remove(url)
                if let image = rep?.nsImage { self?.thumbnails[url] = image }
            }
        }
    }

    // MARK: Actions

    func dismiss(_ shot: Shot) {
        dismissed.insert(shot.url)
        shots.removeAll { $0.url == shot.url }
    }

    func clearAll() {
        dismissed.formUnion(shots.map(\.url))
        shots = []
    }

    func copy(_ shot: Shot) {
        let pb = NSPasteboard.general
        pb.clearContents()
        var objects: [NSPasteboardWriting] = [shot.url as NSURL]
        if !shot.isVideo, let image = NSImage(contentsOf: shot.url) { objects.append(image) }
        pb.writeObjects(objects)
    }

    func trash(_ shot: Shot) {
        NSWorkspace.shared.recycle([shot.url]) { _, _ in }
        dismiss(shot)
    }
}

// MARK: - Widget

struct ScreenshotsWidget: View {
    @ObservedObject var model = ScreenshotModel.shared
    @Environment(\.dockUnit) var u

    private let maxShown = 4

    var body: some View {
        let shots = Array(model.shots.prefix(maxShown))
        let thumbW = u * 1.04
        let gap = u * 0.08
        let n = CGFloat(max(shots.count, 1))
        let width = n * thumbW + (n - 1) * gap + gap + u * 0.3 + u * 0.28

        Tile(span: width / u) {
            HStack(spacing: gap) {
                if shots.isEmpty {
                    // Only visible while rearranging, so the tile has something to grab.
                    VStack(spacing: 3) {
                        Image(systemName: "camera.viewfinder").font(.system(size: u * 0.22))
                        Text("Screenshots").font(.system(size: u * 0.11, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                    .frame(width: thumbW)
                }
                ForEach(shots) { shot in
                    ScreenshotThumb(shot: shot, width: thumbW, height: u * 0.72)
                }
                VStack(spacing: 4) {
                    DockIconButton(symbol: "xmark", size: 0.12, help: "Clear recent screenshots") {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { model.clearAll() }
                    }
                    if model.shots.count > maxShown {
                        Text("+\(model.shots.count - maxShown)")
                            .font(.system(size: u * 0.11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: u * 0.3)
            }
            .padding(.horizontal, u * 0.14)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: shots.map(\.url))
    }
}

struct ScreenshotThumb: View {
    @ObservedObject var model = ScreenshotModel.shared
    @EnvironmentObject var state: AppState
    @Environment(\.dockUnit) var u
    @Environment(\.dockEdge) var edge
    let shot: ScreenshotModel.Shot
    let width: CGFloat
    let height: CGFloat
    @State private var hover = false
    @State private var showPreview = false

    var body: some View {
        let radius = u * 0.1
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Color.primary.opacity(0.08))
            if let thumb = model.thumbnails[shot.url] {
                Image(nsImage: thumb)
                    .resizable()
                    .scaledToFill()
                    .frame(width: width, height: height)
            } else {
                Image(systemName: shot.isVideo ? "video" : "photo")
                    .foregroundStyle(.secondary)
            }
            if shot.isVideo {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: u * 0.2))
                    .foregroundStyle(.white, .black.opacity(0.4))
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(hover ? state.accent : Color.white.opacity(0.2), lineWidth: hover ? 2 : 1)
        )
        .overlay(alignment: .bottomLeading) { timeLeftBadge }
        .overlay(alignment: .topTrailing) {
            if hover {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { model.dismiss(shot) }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: u * 0.17))
                        .foregroundStyle(.white, .black.opacity(0.6))
                }
                .buttonStyle(.plain)
                .padding(3)
                .help("Remove from dock (keeps the file)")
            }
        }
        .scaleEffect(hover ? 1.06 : 1)
        .shadow(color: .black.opacity(hover ? 0.35 : 0), radius: 6, y: 3)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { hover = h } }
        .onTapGesture { showPreview.toggle() }
        .onDrag {
            NSItemProvider(contentsOf: shot.url) ?? NSItemProvider()
        } preview: {
            Image(nsImage: model.thumbnails[shot.url] ?? NSWorkspace.shared.icon(forFile: shot.url.path))
                .resizable()
                .scaledToFit()
                .frame(width: 160, height: 110)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .help("\(shot.url.lastPathComponent)\nDrag into any app, or click to preview")
        .popover(isPresented: $showPreview, arrowEdge: edge.popoverArrow) {
            ScreenshotPreview(shot: shot, close: { showPreview = false })
                .borrowsFocus()
        }
        .contextMenu {
            Button("Copy") { model.copy(shot) }
            Button("Open") { NSWorkspace.shared.open(shot.url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([shot.url]) }
            Divider()
            Button("Remove from Dock") { model.dismiss(shot) }
            Button("Move to Trash") { model.trash(shot) }
        }
    }

    /// "2m" left before it drops off the dock.
    private var timeLeftBadge: some View {
        TimelineView(.periodic(from: .now, by: 15)) { ctx in
            let total = state.config.screenshotMinutes * 60
            let left = max(0, total - ctx.date.timeIntervalSince(shot.created))
            Text(left < 60 ? "<1m" : "\(Int(ceil(left / 60)))m")
                .font(.system(size: u * 0.095, weight: .bold, design: .rounded))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.black.opacity(0.55)))
                .foregroundStyle(.white)
                .padding(3)
        }
    }
}

/// Large preview with quick actions.
struct ScreenshotPreview: View {
    @ObservedObject var model = ScreenshotModel.shared
    let shot: ScreenshotModel.Shot
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                if !shot.isVideo, let full = NSImage(contentsOf: shot.url) {
                    Image(nsImage: full).resizable().scaledToFit()
                } else if let thumb = model.thumbnails[shot.url] {
                    Image(nsImage: thumb).resizable().scaledToFit()
                } else {
                    Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 520, maxHeight: 340)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .onDrag { NSItemProvider(contentsOf: shot.url) ?? NSItemProvider() }

            HStack(spacing: 8) {
                Text(shot.url.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Copy") { model.copy(shot); close() }
                Button("Open") { NSWorkspace.shared.open(shot.url); close() }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([shot.url]); close() }
                Button(role: .destructive) {
                    model.trash(shot)
                    close()
                } label: {
                    Image(systemName: "trash")
                }
                .help("Move to Trash")
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 544)
    }
}
