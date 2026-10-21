import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Shelf actions (shared by the notch shelf and the floating tray)

extension ShelfModel {
    /// Runs a file action off the main thread, adds results to the shelf, and reports in the notch.
    func perform(_ title: String, on urls: [URL], _ work: @escaping ([URL]) async throws -> [URL]) {
        guard !urls.isEmpty else { return }
        busy = title
        Task.detached(priority: .userInitiated) {
            do {
                let outputs = try await work(urls)
                await MainActor.run {
                    self.add(outputs)
                    self.busy = nil
                    self.selection = Set(outputs)
                    LiveActivityCenter.shared.flash(symbol: "checkmark.circle.fill",
                                                    text: outputs.count == 1 ? outputs[0].lastPathComponent : "\(outputs.count) files ready")
                }
            } catch {
                await MainActor.run {
                    self.busy = nil
                    LiveActivityCenter.shared.flash(symbol: "exclamationmark.triangle.fill", text: error.localizedDescription)
                }
            }
        }
    }

    /// The files an action applies to: the selection, or everything if nothing is selected.
    var targets: [URL] {
        let picked = items.filter { selection.contains($0) }
        return picked.isEmpty ? items : picked
    }
}

/// The "Actions" menu: convert, compress, cut out, OCR, GIF, PDF, zip, share.
struct ShelfActionsMenu: View {
    @ObservedObject var shelf = ShelfModel.shared

    static let formats: [String: UTType] = ["PNG": .png, "JPEG": .jpeg, "HEIC": .heic, "TIFF": .tiff]

    var body: some View {
        let urls = shelf.targets
        let images = urls.filter(FileActions.isImage)
        let videos = urls.filter(FileActions.isVideo)
        let pdfable = urls.filter { FileActions.isImage($0) || FileActions.isPDF($0) }

        HStack(spacing: 6) {
            if let busy = shelf.busy {
                ProgressView().controlSize(.small)
                Text(busy).font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
            }
            Menu {
                if !images.isEmpty {
                    Section("Images") {
                        Menu("Convert to") {
                            ForEach(["PNG", "JPEG", "HEIC", "TIFF"], id: \.self) { name in
                                let type = Self.formats[name] ?? UTType.png
                                Button(name) {
                                    shelf.perform("Converting…", on: images) { list in try list.map { try FileActions.convertImage($0, to: type) } }
                                }
                            }
                        }
                        Button("Compress") {
                            shelf.perform("Compressing…", on: images) { list in try list.map(FileActions.compressImage) }
                        }
                        Button("Remove Background") {
                            shelf.perform("Cutting out…", on: images) { list in try list.map(FileActions.removeBackground) }
                        }
                        Button("Copy Text (OCR)") {
                            shelf.perform("Reading text…", on: images) { list in
                                let text = try list.map(FileActions.recognizeText).joined(separator: "\n\n")
                                await MainActor.run {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(text, forType: .string)
                                }
                                return []
                            }
                        }
                    }
                }
                if !videos.isEmpty {
                    Section("Videos") {
                        Button("Compress Video") {
                            shelf.perform("Compressing video…", on: videos) { list in
                                var out: [URL] = []
                                for v in list { out.append(try await FileActions.compressVideo(v)) }
                                return out
                            }
                        }
                        Button("Make GIF") {
                            shelf.perform("Making GIF…", on: videos) { list in
                                var out: [URL] = []
                                for v in list { out.append(try await FileActions.makeGIF(v)) }
                                return out
                            }
                        }
                    }
                }
                Section {
                    if pdfable.count >= 1 {
                        Button(pdfable.count > 1 ? "Combine into PDF" : "Make PDF") {
                            shelf.perform("Making PDF…", on: pdfable) { list in [try FileActions.combineIntoPDF(list)] }
                        }
                    }
                    Button(urls.count > 1 ? "Zip \(urls.count) Items" : "Zip") {
                        shelf.perform("Zipping…", on: urls) { list in [try FileActions.zip(list)] }
                    }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(urls) }
                }
                Section {
                    Button(shelf.selection.isEmpty ? "Clear Shelf" : "Remove Selected") {
                        if shelf.selection.isEmpty { shelf.items.removeAll() } else {
                            shelf.items.removeAll { shelf.selection.contains($0) }
                            shelf.selection.removeAll()
                        }
                    }
                }
            } label: {
                Label(shelf.selection.isEmpty ? "Actions" : "Actions (\(shelf.selection.count))", systemImage: "wand.and.stars")
                    .font(.system(size: 11, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(shelf.items.isEmpty || shelf.busy != nil)

            ShareLink(items: urls) {
                Image(systemName: "square.and.arrow.up").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .disabled(urls.isEmpty)
            .help("Share (AirDrop, Messages, Mail…)")
        }
        .foregroundStyle(.white.opacity(0.85))
    }
}

// MARK: - Floating tray (shake a dragged file to summon it)

/// Watches drags in other apps; a quick side-to-side shake while dragging a file opens the tray.
final class ShakeDetector {
    var onShake: ((NSPoint) -> Void)?
    private var monitor: Any?
    private var samples: [(x: CGFloat, t: TimeInterval)] = []
    private var lastFire: TimeInterval = 0

    func start() {
        guard monitor == nil else { return }
        // Mouse monitoring doesn't need Accessibility (only key events do).
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] e in
            self?.handle(e)
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        samples.removeAll()
    }

    private func handle(_ e: NSEvent) {
        if e.type == .leftMouseUp { samples.removeAll(); return }
        let now = e.timestamp
        samples.append((NSEvent.mouseLocation.x, now))
        samples.removeAll { now - $0.t > 0.7 }
        guard now - lastFire > 1.5, reversals() >= 4 else { return }
        // Only when what's being dragged is a file.
        let drag = NSPasteboard(name: .drag)
        guard drag.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else { return }
        lastFire = now
        samples.removeAll()
        let p = NSEvent.mouseLocation
        DispatchQueue.main.async { self.onShake?(p) }
    }

    /// How many times the pointer changed horizontal direction by at least 25 points.
    private func reversals() -> Int {
        guard samples.count > 3 else { return 0 }
        var count = 0
        var direction: CGFloat = 0
        var anchor = samples[0].x
        for s in samples.dropFirst() {
            if direction == 0 {
                let d = s.x - anchor
                if abs(d) > 25 { direction = d > 0 ? 1 : -1; anchor = s.x }
            } else if direction > 0 {
                if s.x > anchor { anchor = s.x }
                else if anchor - s.x > 25 { count += 1; direction = -1; anchor = s.x }
            } else {
                if s.x < anchor { anchor = s.x }
                else if s.x - anchor > 25 { count += 1; direction = 1; anchor = s.x }
            }
        }
        return count
    }
}

final class FileTrayController {
    static let shared = FileTrayController()
    private var panel: NSPanel?
    private let detector = ShakeDetector()
    private var watcher: Timer?

    func setShakeEnabled(_ on: Bool) {
        if on {
            detector.onShake = { [weak self] p in self?.show(at: p) }
            detector.start()
        } else {
            detector.stop()
        }
    }

    func show(at point: NSPoint? = nil) {
        let p = point ?? NSEvent.mouseLocation
        let size = NSSize(width: 340, height: 190)
        let panel = self.panel ?? makePanel(size: size)
        self.panel = panel
        let screen = NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.screens.first
        var origin = NSPoint(x: p.x - size.width / 2, y: p.y + 30)
        if let vf = screen?.visibleFrame {
            origin.x = min(max(origin.x, vf.minX + 8), vf.maxX - size.width - 8)
            origin.y = min(max(origin.y, vf.minY + 8), vf.maxY - size.height - 8)
        }
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        startWatching()
    }

    func hide() {
        panel?.orderOut(nil)
        watcher?.invalidate()
        watcher = nil
    }

    /// The tray closes itself once everything has been dragged out of it.
    private func startWatching() {
        watcher?.invalidate()
        var hadItems = !ShelfModel.shared.items.isEmpty
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            let empty = ShelfModel.shared.items.isEmpty
            if !empty { hadItems = true }
            if hadItems && empty && NSEvent.pressedMouseButtons == 0 { self?.hide() }
        }
        RunLoop.main.add(t, forMode: .common)
        watcher = t
    }

    private func makePanel(size: NSSize) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: FileTrayView(close: { [weak self] in self?.hide() })
            .environmentObject(AppState.shared))
        return panel
    }
}

struct FileTrayView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var shelf = ShelfModel.shared
    let close: () -> Void
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Label("File Tray", systemImage: "tray.full.fill")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                ShelfActionsMenu()
                Button(action: close) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.6))
                .help("Close (files stay in the notch shelf)")
            }
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(targeted ? state.accent : Color.white.opacity(0.2),
                                  style: StrokeStyle(lineWidth: targeted ? 2 : 1.2, dash: [6, 5]))
                if shelf.items.isEmpty {
                    VStack(spacing: 4) {
                        Image(systemName: "tray.and.arrow.down").font(.system(size: 22))
                        Text("Drop to hold it here").font(.system(size: 11))
                    }
                    .foregroundStyle(.white.opacity(0.6))
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(shelf.items, id: \.self) { ShelfItem(url: $0) }
                        }
                        .padding(.horizontal, 10)
                    }
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                shelf.add(urls)
                return true
            } isTargeted: { targeted = $0 }
        }
        .padding(12)
        .frame(width: 340, height: 190)
        .background(VisualEffect(material: .hudWindow, dark: true, radius: 18))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }
}
