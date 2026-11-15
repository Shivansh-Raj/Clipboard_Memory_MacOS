import AppKit
import Vision
import ClipboardCore

/// Writes stored entries back to the system pasteboard.
final class PasteboardWriter {
    private(set) var ignoredChangeCount: Int = -1
    private let store: HistoryStore
    init(store: HistoryStore) { self.store = store }

    /// Restores the original content. `plain` drops rich formatting.
    @discardableResult
    func restore(id: Int64, plain: Bool = false) -> Bool {
        guard let p = store.payload(id: id) else { return false }
        let pb = NSPasteboard.general
        pb.clearContents()
        switch p.kind {
        case .image:
            guard let url = p.imageURL, let data = try? Data(contentsOf: url) else { return false }
            pb.setData(data, forType: .png)
            if let img = NSImage(data: data), let tiff = img.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
        case .file:
            let urls = p.filePaths.filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) as NSURL }
            if !urls.isEmpty { pb.writeObjects(urls) }
            pb.setString(p.text ?? "", forType: .string)
        default:
            pb.setString(p.text ?? "", forType: .string)
            if !plain {
                if let rtf = p.rtf { pb.setData(rtf, forType: .rtf) }
                if let html = p.html { pb.setData(html, forType: .html) }
            }
        }
        ignoredChangeCount = pb.changeCount
        store.touch(id)
        return true
    }

    /// Puts arbitrary text on the clipboard (used for transforms).
    func write(text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        ignoredChangeCount = pb.changeCount
    }
}

enum OCR {
    static func recognize(imageAt url: URL, completion: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(url: url, options: [:])
            try? handler.perform([request])
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            let text = lines.joined(separator: "\n")
            DispatchQueue.main.async { completion(text) }
        }
    }
}

final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()
    private let queue = DispatchQueue(label: "thumbs", qos: .userInitiated, attributes: .concurrent)
    init() { cache.countLimit = 300 }

    func cached(_ url: URL, size: CGFloat) -> NSImage? { cache.object(forKey: key(url, size)) }

    func load(_ url: URL, size: CGFloat, completion: @escaping (NSImage?) -> Void) {
        let k = key(url, size)
        if let hit = cache.object(forKey: k) { completion(hit); return }
        queue.async {
            var result: NSImage?
            if let src = CGImageSourceCreateWithURL(url as CFURL, nil) {
                let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                              kCGImageSourceCreateThumbnailWithTransform: true,
                                              kCGImageSourceThumbnailMaxPixelSize: size * 2]
                if let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) {
                    result = NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2))
                }
            }
            if let result { self.cache.setObject(result, forKey: k) }
            DispatchQueue.main.async { completion(result) }
        }
    }
    private func key(_ url: URL, _ size: CGFloat) -> NSString { "\(url.lastPathComponent)@\(Int(size))" as NSString }
}
