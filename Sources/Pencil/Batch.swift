import AppKit
import ApplicationServices
import PencilCore

/// A burst's captures. While a batch is open (⇧⌥4 until Esc), every Pencil capture
/// (region, ⌥3, ⌥5 recordings) joins it, and the pasteboard holds ALL of its files as
/// separate pasteboard items, so ⌘V in Finder / Slack / Mail pastes them all.
@MainActor
final class CaptureBatch {
    static let shared = CaptureBatch()

    struct Batch {
        let id: String
        var urls: [URL]
    }

    private(set) var open: Batch?
    /// The most recent batch (open or finished): what ⌥⇧V pastes one by one.
    private(set) var last: Batch?

    var isOpen: Bool { open != nil }

    func begin() {
        let batch = Batch(id: UUID().uuidString, urls: [])
        open = batch
        last = batch
        NSLog("Pencil: burst started \(batch.id)")
    }

    /// Adds a saved capture to the open batch, rewrites the pasteboard with the whole
    /// batch, and records it in the clipboard history. Returns the batch size.
    @discardableResult
    func add(_ url: URL) -> Int {
        guard var batch = open else { return 0 }
        batch.urls.append(url)
        open = batch
        last = batch
        Self.writeToPasteboard(batch.urls)
        ClipboardHistoryController.shared.ingestBatchFile(url, batchID: batch.id)
        NSLog("Pencil: burst \(batch.id) now has \(batch.urls.count) capture(s)")
        return batch.urls.count
    }

    /// Ends the open batch; returns how many captures it has.
    @discardableResult
    func end() -> Int {
        let n = open?.urls.count ?? 0
        if let open { NSLog("Pencil: burst \(open.id) ended with \(n) capture(s)") }
        open = nil
        return n
    }

    /// A batch picked from the history becomes the one ⌥⇧V pastes.
    func setLast(id: String, urls: [URL]) {
        last = Batch(id: id, urls: urls)
    }

    /// One pasteboard item per file: file URL + PNG (+ TIFF) for images, file URL for videos.
    static func pasteboardItems(for urls: [URL]) -> [NSPasteboardItem] {
        urls.compactMap { url in
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            if url.pathExtension.lowercased() == "png", let png = try? Data(contentsOf: url) {
                return ClipboardProcessor.imagePasteboardItem(fileURL: url, png: png)
            }
            return ClipboardProcessor.fileURLItem(url)
        }
    }

    static func writeToPasteboard(_ urls: [URL]) {
        let items = pasteboardItems(for: urls)
        guard !items.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(items)
        ClipboardHistoryController.shared.ignoreOwnPasteboardWrite()
    }
}

/// ⌥⇧V: pastes the last batch one item at a time into the frontmost app (for apps that
/// take one image per paste). Each item goes alone on the pasteboard, then a synthetic
/// ⌘V is posted; afterwards the whole batch is put back. Needs Accessibility.
@MainActor
final class BatchPaster {
    static let shared = BatchPaster()
    private var isPasting = false
    static let accessibilitySettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    static var isTrusted: Bool { AXIsProcessTrusted() }

    func pasteAll(toast: Toast) {
        guard !isPasting else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            NSLog("Pencil: paste all needs Accessibility")
            toast.show("Allow Pencil in Accessibility to paste one by one (menu → Open Accessibility settings)",
                       on: nil, isError: true, duration: 6)
            return
        }
        let urls = CaptureBatch.shared.last?.urls.filter { FileManager.default.fileExists(atPath: $0.path) } ?? []
        isPasting = true
        Task { @MainActor in
            await Self.waitForModifiersReleased()
            if urls.isEmpty {
                // No batch: a normal paste of whatever is current.
                Self.postCommandV()
            } else {
                NSLog("Pencil: pasting \(urls.count) item(s) one by one")
                for url in urls {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.writeObjects(CaptureBatch.pasteboardItems(for: [url]))
                    ClipboardHistoryController.shared.ignoreOwnPasteboardWrite()
                    Self.postCommandV()
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
                CaptureBatch.writeToPasteboard(urls)
            }
            self.isPasting = false
        }
    }

    /// The hotkey's own ⌥⇧ are still held when it fires; wait (briefly) until they're up
    /// so the target app sees a clean ⌘V.
    private static func waitForModifiersReleased() async {
        for _ in 0..<40 {
            let flags = NSEvent.modifierFlags.intersection([.option, .shift, .control, .command])
            if flags.isEmpty { return }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    private static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let v: CGKeyCode = 9
        let down = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
