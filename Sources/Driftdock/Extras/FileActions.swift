import Foundation
import AppKit
import AVFoundation
import Vision
import PDFKit
import CoreImage
import UniformTypeIdentifiers
import ImageIO

/// Droppy-style "Transform" actions. Everything runs on this Mac; results are saved
/// next to the original with a suffix, and never overwrite anything.
enum FileActions {
    enum ActionError: LocalizedError {
        case unreadable, noText, nothingFound, failed(String)
        var errorDescription: String? {
            switch self {
            case .unreadable: return "Couldn't read that file"
            case .noText: return "No text found"
            case .nothingFound: return "No subject found to cut out"
            case .failed(let why): return why
            }
        }
    }

    // MARK: Kinds

    static func type(of url: URL) -> UTType? { UTType(filenameExtension: url.pathExtension.lowercased()) }
    static func isImage(_ url: URL) -> Bool { type(of: url)?.conforms(to: .image) ?? false }
    static func isVideo(_ url: URL) -> Bool { type(of: url)?.conforms(to: .movie) ?? false }
    static func isPDF(_ url: URL) -> Bool { type(of: url)?.conforms(to: .pdf) ?? false }

    /// "Photo 2.png" → "Photo 2 (suffix).ext", adding a number if that exists.
    static func outputURL(for source: URL, suffix: String, ext: String) -> URL {
        let folder = source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent
        var candidate = folder.appendingPathComponent("\(base) (\(suffix)).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) (\(suffix) \(n)).\(ext)")
            n += 1
        }
        return candidate
    }

    // MARK: Images

    static func convertImage(_ url: URL, to type: UTType, quality: Double = 0.9, suffix: String? = nil) throws -> URL {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw ActionError.unreadable }
        let ext = type.preferredFilenameExtension ?? "img"
        let out = outputURL(for: url, suffix: suffix ?? ext.uppercased(), ext: ext)
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, type.identifier as CFString, 1, nil) else {
            throw ActionError.failed("Can't write \(ext.uppercased()) files")
        }
        let props = [kCGImageDestinationLossyCompressionQuality as String: quality] as CFDictionary
        CGImageDestinationAddImage(dest, image, props)
        guard CGImageDestinationFinalize(dest) else { throw ActionError.failed("Couldn't save the image") }
        return out
    }

    /// Re-encodes as JPEG at a lower quality (keeps PNG transparency out of it).
    static func compressImage(_ url: URL) throws -> URL {
        try convertImage(url, to: .jpeg, quality: 0.6, suffix: "compressed")
    }

    /// Copies all text in an image (Vision, on device).
    static func recognizeText(_ url: URL) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(url: url).perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        guard !lines.isEmpty else { throw ActionError.noText }
        return lines.joined(separator: "\n")
    }

    /// Cuts the subject out of a photo and saves a transparent PNG (Vision, on device).
    static func removeBackground(_ url: URL) throws -> URL {
        let handler = VNImageRequestHandler(url: url)
        let request = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([request])
        guard let result = request.results?.first, !result.allInstances.isEmpty else { throw ActionError.nothingFound }
        let buffer = try result.generateMaskedImage(ofInstances: result.allInstances, from: handler,
                                                    croppedToInstancesExtent: false)
        let ci = CIImage(cvPixelBuffer: buffer)
        let context = CIContext()
        guard let cg = context.createCGImage(ci, from: ci.extent) else { throw ActionError.failed("Couldn't render the cutout") }
        let out = outputURL(for: url, suffix: "cutout", ext: "png")
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ActionError.failed("Couldn't save the cutout")
        }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { throw ActionError.failed("Couldn't save the cutout") }
        return out
    }

    // MARK: PDF

    /// Combines images and PDFs, in order, into one PDF.
    static func combineIntoPDF(_ urls: [URL]) throws -> URL {
        let doc = PDFDocument()
        for url in urls {
            if isPDF(url), let other = PDFDocument(url: url) {
                for i in 0..<other.pageCount {
                    if let page = other.page(at: i) { doc.insert(page, at: doc.pageCount) }
                }
            } else if isImage(url), let image = NSImage(contentsOf: url), let page = PDFPage(image: image) {
                doc.insert(page, at: doc.pageCount)
            }
        }
        guard doc.pageCount > 0, let first = urls.first else { throw ActionError.failed("Nothing to combine") }
        let out = outputURL(for: first, suffix: "combined", ext: "pdf")
        guard doc.write(to: out) else { throw ActionError.failed("Couldn't save the PDF") }
        return out
    }

    // MARK: Zip

    static func zip(_ urls: [URL]) throws -> URL {
        guard let first = urls.first else { throw ActionError.failed("Nothing to zip") }
        let fm = FileManager.default
        if urls.count == 1 {
            let out = outputURL(for: first, suffix: "zip", ext: "zip")
            try run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", first.path, out.path])
            return out
        }
        // Several items: stage copies in a temp folder and zip that.
        let staging = fm.temporaryDirectory.appendingPathComponent("Driftdock-\(UUID().uuidString)/Archive")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging.deletingLastPathComponent()) }
        for url in urls {
            try fm.copyItem(at: url, to: staging.appendingPathComponent(url.lastPathComponent))
        }
        let out = outputURL(for: first.deletingLastPathComponent().appendingPathComponent("Archive"), suffix: "\(urls.count) items", ext: "zip")
        try run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", staging.path, out.path])
        return out
    }

    private static func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardError = Pipe()
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw ActionError.failed("\(URL(fileURLWithPath: tool).lastPathComponent) failed") }
    }

    // MARK: Video

    /// Re-encodes to 1080p HEVC, usually a fraction of the size.
    static func compressVideo(_ url: URL) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHEVC1920x1080) else {
            throw ActionError.failed("This video can't be compressed")
        }
        let out = outputURL(for: url, suffix: "compressed", ext: "mov")
        export.outputURL = out
        export.outputFileType = .mov
        export.shouldOptimizeForNetworkUse = true
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { done.resume() }
        }
        guard export.status == .completed else {
            throw ActionError.failed(export.error?.localizedDescription ?? "Compression failed")
        }
        return out
    }

    /// Turns the first 10 seconds of a video into a looping GIF.
    static func makeGIF(_ url: URL) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let length = min(max(duration, 0.1), 10)
        let fps = 12.0
        let frames = max(1, Int(length * fps))

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)

        let out = outputURL(for: url, suffix: "gif", ext: "gif")
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString, frames, nil) else {
            throw ActionError.failed("Couldn't create the GIF")
        }
        let fileProps = [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFLoopCount as String: 0]] as CFDictionary
        CGImageDestinationSetProperties(dest, fileProps)
        let frameProps = [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFDelayTime as String: 1.0 / fps]] as CFDictionary

        for i in 0..<frames {
            let time = CMTime(seconds: Double(i) / fps, preferredTimescale: 600)
            if let image = try? await generator.image(at: time).image {
                CGImageDestinationAddImage(dest, image, frameProps)
            }
        }
        guard CGImageDestinationFinalize(dest) else { throw ActionError.failed("Couldn't save the GIF") }
        return out
    }
}
