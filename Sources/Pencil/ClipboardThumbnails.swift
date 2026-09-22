import AppKit
import ImageIO
import PencilCore
import QuickLookThumbnailing

/// Loads and caches previews for history items off the main thread.
///
/// Two sizes: `.row` (list rows and the tab, backed by the stored thumb.png when there
/// is one) and `.large` (the current card and the hover preview, decoded from the full
/// image or rendered by Quick Look). Requests for the same key are coalesced.
@MainActor
final class ClipboardThumbnails {
    enum Size: Int {
        case row = 240
        case large = 900
    }

    private let disk: ClipboardStoreDisk
    private let cache = NSCache<NSString, NSImage>()
    private var waiting: [String: [(NSImage?) -> Void]] = [:]
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "pencil.clipboard.thumbnails"
        q.maxConcurrentOperationCount = 3
        q.qualityOfService = .userInitiated
        return q
    }()

    init(disk: ClipboardStoreDisk) {
        self.disk = disk
        cache.countLimit = 600
    }

    private func key(_ item: ClipboardItem, _ size: Size) -> String {
        "\(item.id)|\(size.rawValue)|\(item.thumbnailFile ?? "-")"
    }

    /// A cached preview right away, if there is one.
    func cached(_ item: ClipboardItem, size: Size) -> NSImage? {
        cache.object(forKey: key(item, size) as NSString)
    }

    /// Delivers a preview on the main thread (nil if none can be made). Text items have none.
    func load(_ item: ClipboardItem, size: Size, completion: @escaping (NSImage?) -> Void) {
        guard item.kind != .text else { return completion(nil) }
        let k = key(item, size)
        if let hit = cache.object(forKey: k as NSString) { return completion(hit) }
        if waiting[k] != nil {
            waiting[k]?.append(completion)
            return
        }
        waiting[k] = [completion]

        let disk = self.disk
        queue.addOperation { [weak self] in
            Self.render(item, size: size, disk: disk) { image in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.finish(k, image) }
                }
            }
        }
    }

    private func finish(_ key: String, _ image: NSImage?) {
        if let image { cache.setObject(image, forKey: key as NSString) }
        let callbacks = waiting.removeValue(forKey: key) ?? []
        callbacks.forEach { $0(image) }
    }

    // MARK: Rendering (background)

    private nonisolated static func render(_ item: ClipboardItem, size: Size, disk: ClipboardStoreDisk,
                                           done: @escaping (NSImage?) -> Void) {
        let px = size.rawValue
        // Rows: the stored thumbnail is already the right size.
        if size == .row, let url = disk.blobURL(item.thumbnailFile, of: item.id),
           let image = NSImage(contentsOf: url) {
            return done(image)
        }
        switch item.kind {
        case .text:
            done(nil)
        case .image:
            let url = disk.blobURL(item.imageFile, of: item.id)
            done(url.flatMap { downsampled($0, px) })
        case .file:
            guard let path = item.filePaths.first else { return done(nil) }
            let url = URL(fileURLWithPath: path)
            if !item.isVideo, item.pixelWidth != nil, let image = downsampled(url, px) {
                return done(image)
            }
            quickLook(url, px) { image in
                done(image ?? (FileManager.default.fileExists(atPath: path)
                    ? NSWorkspace.shared.icon(forFile: path) : nil))
            }
        }
    }

    nonisolated static func downsampled(_ url: URL, _ px: Int) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = ClipboardProcessor.downsample(src, maxPixels: px) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / 2, height: CGFloat(cg.height) / 2))
    }

    /// Quick Look thumbnail (videos, PDFs, documents). Calls back on an arbitrary queue.
    nonisolated static func quickLook(_ url: URL, _ px: Int, done: @escaping (NSImage?) -> Void) {
        guard FileManager.default.fileExists(atPath: url.path) else { return done(nil) }
        let side = CGFloat(px) / 2
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side),
                                                   scale: 2, representationTypes: [.thumbnail, .icon])
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
            done(rep?.nsImage)
        }
    }

    /// Renders a Quick Look thumbnail to PNG for storing as an item's thumb.png.
    nonisolated static func quickLookPNG(_ url: URL, done: @escaping (Data?) -> Void) {
        let side = CGFloat(ClipboardProcessor.thumbnailPixels) / 2
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side),
                                                   scale: 2, representationTypes: [.thumbnail])
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
            done(rep.flatMap { ClipboardProcessor.encodePNG($0.cgImage) })
        }
    }
}
