import AppKit
import PencilCore
import UniformTypeIdentifiers

/// Makes ⌘V of an image work in terminals (Claude Code in Terminal, iTerm, Ghostty, …).
/// Terminals only read plain text, so while one is frontmost and the pasteboard holds an
/// image or image/video file with no text, the same content is rewritten with the file's
/// escaped path added as text. When another app comes to the front, that text is taken
/// off again, so chat apps keep getting the image. A newer copy by the user is never touched.
@MainActor
final class TerminalPasteBridge {
    static let shared = TerminalPasteBridge()

    private enum Key { static let enabled = "terminalBridge.enabled" }
    private static let textTypes: Set<String> = [
        NSPasteboard.PasteboardType.string.rawValue, "NSStringPboardType", "public.plain-text",
        "public.utf16-plain-text", "public.utf16-external-plain-text",
    ]
    private static let imageDataTypes: [NSPasteboard.PasteboardType] = [
        .png, .tiff, NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic"),
    ]

    /// The change count of our "with path" write while it's on the pasteboard.
    private var bridgedChangeCount: Int?
    private var started = false
    private var pending = false

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Key.enabled) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: Key.enabled)
            evaluate()
        }
    }

    func start() {
        guard !started else { return }
        started = true
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { TerminalPasteBridge.shared.evaluate() }
        }
        evaluate()
    }

    /// The pasteboard changed (someone's copy, or a Pencil write): re-check on the next turn,
    /// after the writer has finished.
    func pasteboardChanged() {
        guard started, !pending else { return }
        pending = true
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let bridge = TerminalPasteBridge.shared
                bridge.pending = false
                bridge.evaluate()
            }
        }
    }

    // MARK: Deciding

    private func evaluate() {
        let pb = NSPasteboard.general
        let items = pb.pasteboardItems ?? []
        let types = Set(items.flatMap { $0.types.map(\.rawValue) })
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let action = TerminalPaste.decide(
            frontIsTerminal: TerminalPaste.isTerminal(front), enabled: isEnabled,
            hasPlainText: !types.isDisjoint(with: Self.textTypes),
            hasImageOrMedia: items.first.map(Self.isImageOrMedia) ?? false,
            bridgedChangeCount: bridgedChangeCount, changeCount: pb.changeCount)
        switch action {
        case .none:
            break
        case .forget:
            // Something newer is on the pasteboard; judge it on its own.
            bridgedChangeCount = nil
            evaluate()
        case .addPath:
            addPath(items)
        case .removePath:
            removePath(items)
        }
    }

    private static func isImageOrMedia(_ item: NSPasteboardItem) -> Bool {
        if let url = fileURL(of: item) {
            guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
            return type.conforms(to: .image) || type.conforms(to: .movie) || type.conforms(to: .audiovisualContent)
        }
        return imageDataTypes.contains { item.types.contains($0) }
    }

    private static func fileURL(of item: NSPasteboardItem) -> URL? {
        item.string(forType: .fileURL).flatMap(URL.init(string:)).flatMap { $0.isFileURL ? $0 : nil }
    }

    // MARK: Writing

    private func addPath(_ items: [NSPasteboardItem]) {
        // Let the history see this copy first, so our rewrite doesn't hide it from it.
        ClipboardHistoryController.shared.pollPasteboardNow()
        var paths = items.compactMap(Self.fileURL(of:)).map(\.path)
        if paths.isEmpty, let first = items.first,
           let data = Self.imageDataTypes.lazy.compactMap({ first.data(forType: $0) }).first,
           let path = ClipboardHistoryController.shared.storedImagePath(forPasteboardImage: data) {
            // An image with no file (a macOS screenshot to the clipboard): the PNG in the history.
            paths = [path]
        }
        guard !paths.isEmpty else { return }
        let text = TerminalPaste.pasteText(for: paths)
        let copies = items.map { Self.copy($0, dropping: []) }
        copies[0].setString(text, forType: .string)
        bridgedChangeCount = write(copies)
        NSLog("Pencil: terminal bridge added path \(text)")
    }

    private func removePath(_ items: [NSPasteboardItem]) {
        bridgedChangeCount = nil
        let copies = items.map { Self.copy($0, dropping: Self.textTypes) }
        _ = write(copies)
        NSLog("Pencil: terminal bridge removed path")
    }

    private func write(_ items: [NSPasteboardItem]) -> Int {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(items)
        // Our own write: not a new history entry, and no re-trigger of the bridge.
        ClipboardHistoryController.shared.ignoreOwnPasteboardWrite(notify: false)
        return pb.changeCount
    }

    private static func copy(_ item: NSPasteboardItem, dropping: Set<String>) -> NSPasteboardItem {
        let out = NSPasteboardItem()
        for type in item.types where !dropping.contains(type.rawValue) && !type.rawValue.hasPrefix("dyn.") {
            if let data = item.data(forType: type) { out.setData(data, forType: type) }
        }
        return out
    }
}
