import AppKit
import CryptoKit
import ImageIO
import PencilCore
import UniformTypeIdentifiers

/// What was on the pasteboard at one change, read on the main thread and then
/// handed to a background queue. Plain values only.
struct ClipboardCapture: @unchecked Sendable {
    var kind: ClipboardItem.Kind
    var fileURLs: [URL] = []
    var imageData: Data?
    var text: String?
    var rtf: Data?
    var date: Date
}

/// Polls `NSPasteboard.general.changeCount` and reports each new copy. Skips
/// password-manager and other marked content, its own writes, and everything while paused.
@MainActor
final class ClipboardWatcher {
    static let interval: TimeInterval = 0.4

    var isPaused = false
    /// Called on the main thread for every change worth saving.
    var onCapture: ((ClipboardCapture) -> Void)?

    private var timer: Timer?
    private var lastChangeCount: Int
    private let pasteboard = NSPasteboard.general

    init() {
        lastChangeCount = NSPasteboard.general.changeCount
    }

    /// Starts polling. `includeCurrent` saves what is on the clipboard right now
    /// (de-duplicated against the saved history, so a relaunch doesn't add it twice).
    func start(includeCurrent: Bool) {
        guard timer == nil else { return }
        if includeCurrent { lastChangeCount = -1 }
        let t = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        t.tolerance = 0.1
        // .common so it keeps running while a menu is open or a drag is tracking.
        RunLoop.main.add(t, forMode: .common)
        timer = t
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Called after any new pasteboard content: someone else's copy (`own: false`, after it
    /// was read) or a write by Pencil (`own: true`). The terminal paste bridge listens.
    var onChange: ((_ own: Bool) -> Void)?

    /// Call right after Pencil wrote the pasteboard itself, so that write isn't saved again.
    /// `notify: false` for writes that must not trigger `onChange` (the bridge's own).
    func ignoreCurrentChange(notify: Bool = true) {
        lastChangeCount = pasteboard.changeCount
        if notify { onChange?(true) }
    }

    /// Reads a pending change right away instead of waiting for the next tick.
    func pollNow() { poll() }

    private func poll() {
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        if !isPaused, let capture = Self.read(pasteboard) { onCapture?(capture) }
        onChange?(false)
    }

    /// Reads the pasteboard into a capture, or nil for content that must not or can't be saved.
    static func read(_ pb: NSPasteboard) -> ClipboardCapture? {
        let types = (pb.types ?? []).map(\.rawValue)
        guard !types.isEmpty, !ClipboardPrivacy.shouldIgnore(types: types) else { return nil }

        let urls = (pb.readObjects(forClasses: [NSURL.self],
                                   options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff,
                                                         NSPasteboard.PasteboardType("public.jpeg"),
                                                         NSPasteboard.PasteboardType("public.heic")]
        let hasImage = imageTypes.contains { types.contains($0.rawValue) }
        let text = pb.string(forType: .string)

        guard let kind = ClipboardClassifier.kind(hasFileURLs: !urls.isEmpty, hasImage: hasImage,
                                                  plainText: text) else { return nil }
        var capture = ClipboardCapture(kind: kind, date: Date())
        switch kind {
        case .file:
            capture.fileURLs = urls
        case .image:
            capture.imageData = imageTypes.lazy.compactMap { pb.data(forType: $0) }.first
            if capture.imageData == nil { return nil }
        case .text:
            capture.text = text
            if let rtf = pb.data(forType: .rtf), rtf.count <= ClipboardProcessor.richTextLimit {
                capture.rtf = rtf
            }
        }
        return capture
    }
}

/// Turns captures into history items (hashing, writing blobs, thumbnails) off the
/// main thread, and writes items back to the pasteboard.
enum ClipboardProcessor {
    /// Longer text keeps this many characters in the index and the rest in a blob.
    static let inlineTextLimit = 32 * 1024
    /// Rich text is kept only when it's cheap.
    static let richTextLimit = 1024 * 1024
    /// Stored thumbnails (list rows, the tab): long side in pixels.
    static let thumbnailPixels = 240

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Content identity for de-duplication. Runs off the main thread (hashes images).
    static func fingerprint(_ c: ClipboardCapture) -> String {
        switch c.kind {
        case .file: return ClipboardFingerprint.files(c.fileURLs.map(\.path))
        case .image: return "image:" + sha256(c.imageData ?? Data())
        case .text: return "text:" + sha256(Data((c.text ?? "").utf8))
        }
    }

    /// Builds the item and writes its blobs into its own folder. Background only.
    static func build(_ c: ClipboardCapture, fingerprint: String, disk: ClipboardStoreDisk) -> ClipboardItem? {
        var item = ClipboardItem(kind: c.kind, fingerprint: fingerprint, copiedAt: c.date)
        var bytes: Int64 = 0
        do {
            switch c.kind {
            case .text:
                let text = c.text ?? ""
                if text.count > inlineTextLimit {
                    bytes += try disk.writeBlob(Data(text.utf8), named: "text.txt", for: item.id)
                    item.fullTextFile = "text.txt"
                    item.text = String(text.prefix(inlineTextLimit))
                } else {
                    item.text = text
                }
                bytes += Int64(item.text?.utf8.count ?? 0)
                if let rtf = c.rtf {
                    bytes += try disk.writeBlob(rtf, named: "rich.rtf", for: item.id)
                    item.richTextFile = "rich.rtf"
                }

            case .image:
                guard let data = c.imageData, let png = pngData(from: data) else { return nil }
                let name = imageFileName(for: c.date)
                bytes += try disk.writeBlob(png.data, named: name, for: item.id)
                item.imageFile = name
                item.pixelWidth = png.width
                item.pixelHeight = png.height
                item.fileSize = Int64(png.data.count)
                item.imageHash = CGImageSourceCreateWithData(png.data as CFData, nil).flatMap(imageHash(from:))
                if let thumb = thumbnailPNG(fromImageData: png.data) {
                    bytes += try disk.writeBlob(thumb, named: "thumb.png", for: item.id)
                    item.thumbnailFile = "thumb.png"
                }

            case .file:
                let urls = c.fileURLs
                item.filePaths = urls.map(\.path)
                guard let first = urls.first else { return nil }
                let values = try? first.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey,
                                                                 .localizedTypeDescriptionKey, .isDirectoryKey])
                let type = values?.contentType
                item.fileTypeIdentifier = type?.identifier
                item.fileTypeName = values?.localizedTypeDescription ?? type?.localizedDescription
                if values?.isDirectory != true {
                    item.fileSize = urls.reduce(Int64(0)) {
                        $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                    }
                }
                item.isVideo = type.map { $0.conforms(to: .movie) || $0.conforms(to: .video) } ?? false
                if let type, type.conforms(to: .image), let src = CGImageSourceCreateWithURL(first as CFURL, nil) {
                    let size = pixelSize(src)
                    item.pixelWidth = size?.width
                    item.pixelHeight = size?.height
                    item.imageHash = imageHash(from: src)
                    if let thumb = thumbnailPNG(from: src) {
                        bytes += try disk.writeBlob(thumb, named: "thumb.png", for: item.id)
                        item.thumbnailFile = "thumb.png"
                    }
                }
                // Videos and other files get a Quick Look thumbnail after insertion
                // (ClipboardHistoryController.generateFileThumbnail), which is asynchronous.
            }
        } catch {
            NSLog("Pencil: clipboard blob write failed: \(error)")
            disk.removeFolder(for: item.id)
            return nil
        }
        item.storedBytes = bytes
        return item
    }

    static func imageFileName(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "clipboard-\(f.string(from: date)).png"
    }

    // MARK: ImageIO

    private static func pixelSize(_ src: CGImageSource) -> (width: Int, height: Int)? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        // EXIF orientations 5–8 are rotated a quarter turn.
        if let o = props[kCGImagePropertyOrientation] as? Int, (5...8).contains(o) { return (h, w) }
        return (w, h)
    }

    /// PNG data as-is, or anything ImageIO reads (TIFF, JPEG, HEIC) converted to PNG.
    static func pngData(from data: Data) -> (data: Data, width: Int, height: Int)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let size = pixelSize(src) ?? (0, 0)
        if CGImageSourceGetType(src) as String? == UTType.png.identifier {
            return (data, size.width, size.height)
        }
        guard let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (out as Data, image.width, image.height)
    }

    static func downsample(_ src: CGImageSource, maxPixels: Int) -> CGImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// Perceptual hash (dHash) as hex, from a small downsample. Background only.
    static func imageHash(from src: CGImageSource) -> String? {
        downsample(src, maxPixels: 64).flatMap(ClipboardImageHash.dHash).map(ClipboardImageHash.hex)
    }

    static func imageHash(at url: URL) -> String? {
        CGImageSourceCreateWithURL(url as CFURL, nil).flatMap(imageHash(from:))
    }

    static func encodePNG(_ image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    private static func thumbnailPNG(from src: CGImageSource) -> Data? {
        downsample(src, maxPixels: thumbnailPixels).flatMap(encodePNG)
    }

    private static func thumbnailPNG(fromImageData data: Data) -> Data? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap(thumbnailPNG(from:))
    }

    // MARK: Writing back

    enum WriteResult { case written, missingFiles }

    /// Puts an item back on the pasteboard in the richest form it was saved in, but never
    /// with a plain-text path next to a picture or file: apps that check for text before
    /// images would paste the path instead of the image.
    /// - text: the string (+ RTF when kept)
    /// - images, and single image files (Pencil snapshots): file URL + PNG + TIFF
    /// - other files: file URLs only
    @MainActor
    static func write(_ item: ClipboardItem, disk: ClipboardStoreDisk, to pb: NSPasteboard = .general) -> WriteResult {
        switch item.kind {
        case .text:
            let pbItem = NSPasteboardItem()
            let full = disk.blobURL(item.fullTextFile, of: item.id).flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            pbItem.setString(full ?? item.text ?? "", forType: .string)
            if let url = disk.blobURL(item.richTextFile, of: item.id), let rtf = try? Data(contentsOf: url) {
                pbItem.setData(rtf, forType: .rtf)
            }
            pb.clearContents()
            pb.writeObjects([pbItem])

        case .image:
            guard let url = disk.blobURL(item.imageFile, of: item.id), let png = try? Data(contentsOf: url) else {
                return .missingFiles
            }
            pb.clearContents()
            pb.writeObjects([imagePasteboardItem(fileURL: url, png: png)])

        case .file:
            let urls = item.filePaths.map { URL(fileURLWithPath: $0) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            guard !urls.isEmpty else { return .missingFiles }
            if urls.count == 1, item.pixelWidth != nil, !item.isVideo,
               let data = try? Data(contentsOf: urls[0]), let png = pngData(from: data) {
                pb.clearContents()
                pb.writeObjects([imagePasteboardItem(fileURL: urls[0], png: png.data)])
            } else {
                pb.clearContents()
                pb.writeObjects(urls.map(fileURLItem))
            }
        }
        return .written
    }

    /// One file, as a file URL and nothing else.
    static func fileURLItem(_ url: URL) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        return item
    }

    /// File URL, PNG, and TIFF (skipped for very large PNGs, whose TIFF conversion would
    /// stall the click; PNG covers modern apps). No text types.
    static func imagePasteboardItem(fileURL url: URL, png: Data) -> NSPasteboardItem {
        let item = fileURLItem(url)
        item.setData(png, forType: .png)
        if png.count <= 8 * 1024 * 1024, let tiff = NSImage(data: png)?.tiffRepresentation {
            item.setData(tiff, forType: .tiff)
        }
        return item
    }
}
