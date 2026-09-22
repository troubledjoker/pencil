import Foundation
import ImageIO
import PencilCore
import Vision

/// Finds the text in clipboard images (Vision, accurate, with language correction) so
/// search can match screenshots. Runs one image at a time off the main thread. New
/// copies go first; the backfill of older items runs at background priority.
final class ClipboardOCR: @unchecked Sendable {
    /// Stored OCR text is capped; it's for search, not for reading.
    static let maxCharacters = 20_000
    /// Larger images are downscaled first; text stays legible and Vision is much faster.
    static let maxPixels = 3000

    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "pencil.clipboard.ocr"
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .utility
        return q
    }()

    /// Recognizes the text in the image at `url`. `done` gets "" when there is none,
    /// nil if the image couldn't be read (try again another time). Called on a background queue.
    func recognize(_ url: URL, backfill: Bool, done: @escaping @Sendable (String?) -> Void) {
        let op = BlockOperation { done(Self.recognizeNow(url)) }
        op.queuePriority = backfill ? .veryLow : .normal
        op.qualityOfService = backfill ? .background : .utility
        queue.addOperation(op)
    }

    static func recognizeNow(_ url: URL) -> String? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = ClipboardProcessor.downsample(src, maxPixels: maxPixels) else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            NSLog("Pencil: clipboard OCR failed for \(url.lastPathComponent): \(error)")
            return ""
        }
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return String(lines.joined(separator: "\n").prefix(maxCharacters))
    }
}
