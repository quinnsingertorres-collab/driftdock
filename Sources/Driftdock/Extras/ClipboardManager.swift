import SwiftUI
import AppKit
import Vision

/// One clipboard entry: text or an image. Pinned entries stay at the top and survive restarts.
struct ClipItem: Identifiable, Equatable, Codable {
    enum Kind: String, Codable { case text, image }

    var id = UUID()
    var kind: Kind
    var text: String = ""
    /// PNG data for images (scaled down so history stays light).
    var imageData: Data?
    var pinned = false
    var title: String?
    var date = Date()

    var image: NSImage? { imageData.flatMap(NSImage.init(data:)) }

    var displayText: String {
        if let title, !title.isEmpty { return title }
        switch kind {
        case .text: return text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        case .image: return "Image"
        }
    }
}

/// Clipboard history (Droppy-style Clipboard Manager): text and images, pinning, OCR, drag out.
final class ClipboardModel: ObservableObject {
    static let shared = ClipboardModel()

    @Published private(set) var items: [ClipItem] = []

    /// Text entries only, newest first (used by the dock widget).
    var history: [String] { items.filter { $0.kind == .text }.map(\.text) }

    private var changeCount = NSPasteboard.general.changeCount
    private var timer: Timer?
    private var ignoreNextChange = false
    private let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private let pinnedKey = "driftdock.clipboard.pinned.v1"
    private let maxItems = 40

    private init() {
        if let data = UserDefaults.standard.data(forKey: pinnedKey),
           let saved = try? JSONDecoder().decode([ClipItem].self, from: data) {
            items = saved
        }
        let t = Timer(timeInterval: 0.7, repeats: true) { [weak self] _ in self?.check() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func check() {
        let pb = NSPasteboard.general
        guard pb.changeCount != changeCount else { return }
        changeCount = pb.changeCount
        if ignoreNextChange { ignoreNextChange = false; return }
        // Respect password managers that mark copies as concealed.
        if pb.types?.contains(concealed) == true { return }

        if let s = pb.string(forType: .string), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            insert(ClipItem(kind: .text, text: s)) { $0.kind == .text && $0.text == s }
        } else if let image = NSImage(pasteboard: pb), let data = Self.thumbnailPNG(image) {
            insert(ClipItem(kind: .image, imageData: data)) { $0.kind == .image && $0.imageData == data }
        }
    }

    private func insert(_ item: ClipItem, sameAs: (ClipItem) -> Bool) {
        if let existing = items.firstIndex(where: sameAs) {
            var moved = items.remove(at: existing)
            moved.date = Date()
            items.insert(moved, at: moved.pinned ? 0 : pinnedCount)
        } else {
            items.insert(item, at: pinnedCount)
        }
        // Trim the oldest unpinned entries.
        while items.count > maxItems, let last = items.lastIndex(where: { !$0.pinned }) {
            items.remove(at: last)
        }
    }

    private var pinnedCount: Int { items.filter(\.pinned).count }

    private static func thumbnailPNG(_ image: NSImage, maxSide: CGFloat = 800) -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, maxSide / max(size.width, size.height))
        let target = NSSize(width: size.width * scale, height: size.height * scale)
        let resized = NSImage(size: target)
        resized.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: target))
        resized.unlockFocus()
        guard let tiff = resized.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: Actions

    func copy(_ s: String) {
        ignoreNextChange = true
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }

    func copy(_ item: ClipItem) {
        ignoreNextChange = item.kind == .image   // don't re-add the same image as a new entry
        let pb = NSPasteboard.general
        pb.clearContents()
        switch item.kind {
        case .text: pb.setString(item.text, forType: .string)
        case .image: if let image = item.image { pb.writeObjects([image]) }
        }
    }

    func togglePin(_ item: ClipItem) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        var it = items.remove(at: i)
        it.pinned.toggle()
        items.insert(it, at: it.pinned ? 0 : pinnedCount)
        savePinned()
    }

    func rename(_ item: ClipItem, to title: String) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i].title = title.isEmpty ? nil : title
        savePinned()
    }

    func remove(_ item: ClipItem) {
        items.removeAll { $0.id == item.id }
        savePinned()
    }

    func clearUnpinned() {
        items.removeAll { !$0.pinned }
    }

    /// Pulls the text out of an image entry and copies it.
    func copyText(from item: ClipItem) {
        guard let cg = item.image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            try? VNImageRequestHandler(cgImage: cg).perform([request])
            let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            DispatchQueue.main.async {
                guard !text.isEmpty else {
                    LiveActivityCenter.shared.flash(symbol: "text.viewfinder", text: "No text found")
                    return
                }
                self.copy(text)
                LiveActivityCenter.shared.flash(symbol: "text.viewfinder", text: "Text copied")
            }
        }
    }

    /// Something to hand to a drag: the text, or the image as a PNG file.
    func dragProvider(for item: ClipItem) -> NSItemProvider {
        switch item.kind {
        case .text:
            return NSItemProvider(object: item.text as NSString)
        case .image:
            guard let data = item.imageData else { return NSItemProvider() }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Clipboard \(item.id.uuidString.prefix(6)).png")
            try? data.write(to: url)
            return NSItemProvider(contentsOf: url) ?? NSItemProvider()
        }
    }

    private func savePinned() {
        let pinned = items.filter(\.pinned)
        if let data = try? JSONEncoder().encode(pinned) {
            UserDefaults.standard.set(data, forKey: pinnedKey)
        }
    }
}
