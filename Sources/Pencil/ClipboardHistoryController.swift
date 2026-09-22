import AppKit
import PencilCore
import UniformTypeIdentifiers

/// Clipboard history: saves every copy, keeps it on disk, and shows it in a dark
/// sidebar on the right edge (opened from the dock's Clipboard button, ⌃⌘V, or the menu).
/// One entry point for the app:
///
///     ClipboardHistoryController.shared.start()   // once, at launch
///     ClipboardHistoryController.shared.toggle()  // hotkey / menu
///
/// See docs/CLIPBOARD.md for the integration lines.
@MainActor
final class ClipboardHistoryController {
    static let shared = ClipboardHistoryController()

    /// Private pasteboard type that identifies a dragged row inside the panel.
    static let rowDragType = NSPasteboard.PasteboardType("com.haim.pencil.clipboard-row")
    /// Shown in hover hints. Keep in sync with the hotkey registered in App.swift.
    static let hotkeyLabel = Shortcuts.Global.clipboard.label

    let disk = ClipboardStoreDisk(root: ClipboardStoreDisk.defaultRoot)
    let thumbnails: ClipboardThumbnails
    private(set) var store = ClipboardStore()

    private let watcher = ClipboardWatcher()
    /// Serial: blob writes, deletes and index saves never overlap.
    private let work = DispatchQueue(label: "pencil.clipboard.store", qos: .utility)
    private let ocr = ClipboardOCR()
    private var panel: ClipboardPanelController?
    private var started = false
    private var saveScheduled = false

    private enum Key {
        static let paused = "clipboard.paused"
        /// Left over from the removed right-edge tab; deleted on start.
        static let obsolete = ["clipboard.tab.offsetY", "clipboard.tab.displayID"]
    }

    /// Called after every change to the history (the panel refreshes itself).
    private var observers: [() -> Void] = []
    /// Called when the sidebar opens or closes (the dock's Clipboard button shows it).
    private var openObservers: [(Bool) -> Void] = []

    private init() {
        thumbnails = ClipboardThumbnails(disk: disk)
    }

    // MARK: Entry points

    /// Loads the saved history, starts watching the pasteboard. Idempotent.
    func start() {
        guard !started else { return }
        started = true

        store = ClipboardStore(items: disk.loadItems())
        store.prune()
        // Sweep folders nothing refers to before any new blobs are written (same serial queue).
        let disk = self.disk
        let ids = Set(store.items.map(\.id))
        work.async { disk.removeOrphans(keeping: ids) }

        Key.obsolete.forEach(UserDefaults.standard.removeObject(forKey:))
        let panel = ClipboardPanelController(history: self)
        panel.onVisibilityChange = { [weak self] open in self?.openObservers.forEach { $0(open) } }
        self.panel = panel
        backfillOCR()
        backfillImageHashes()

        watcher.isPaused = UserDefaults.standard.bool(forKey: Key.paused)
        watcher.onCapture = { [weak self] capture in self?.handle(capture) }
        watcher.onChange = { _ in TerminalPasteBridge.shared.pasteboardChanged() }
        watcher.start(includeCurrent: true)
        TerminalPasteBridge.shared.start()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
    }

    /// Opens the panel, or closes it (returning focus to the previous app).
    func toggle() {
        guard started, let panel else { return }
        if panel.isOpen { panel.close(restoreFocus: true) } else { show() }
    }

    /// Opens the sidebar on the screen under the mouse.
    func show() {
        guard started, let panel else { return }
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main ?? NSScreen.screens.first else { return }
        panel.open(on: screen)
    }

    func hide() {
        panel?.close(restoreFocus: true)
    }

    var isOpen: Bool { panel?.isOpen ?? false }

    func screensChanged() {
        if let panel, panel.isOpen { panel.close(restoreFocus: false) }
    }

    // MARK: Observing

    func observe(_ block: @escaping () -> Void) {
        observers.append(block)
    }

    func observeOpen(_ block: @escaping (Bool) -> Void) {
        openObservers.append(block)
    }

    private func changed(save: Bool = true) {
        observers.forEach { $0() }
        if save { scheduleSave() }
    }

    // MARK: Saving new copies

    var isPaused: Bool { watcher.isPaused }

    func setPaused(_ paused: Bool) {
        watcher.isPaused = paused
        UserDefaults.standard.set(paused, forKey: Key.paused)
        changed(save: false)
    }

    /// Pencil wrote the pasteboard itself (a batch, a one-by-one paste): don't save it again.
    func ignoreOwnPasteboardWrite(notify: Bool = true) {
        watcher.ignoreCurrentChange(notify: notify)
    }

    /// Reads a pending pasteboard change right away (before the bridge rewrites it).
    func pollPasteboardNow() {
        watcher.pollNow()
    }

    /// A file path for image data on the pasteboard (for pasting into a terminal): the PNG
    /// already in the history, or saved into it now. While history is paused, a temporary file.
    func storedImagePath(forPasteboardImage data: Data) -> String? {
        let fingerprint = "image:" + ClipboardProcessor.sha256(data)
        if let item = store.item(fingerprint: fingerprint), let url = disk.blobURL(item.imageFile, of: item.id),
           FileManager.default.fileExists(atPath: url.path) {
            return url.path
        }
        if isPaused {
            guard let png = ClipboardProcessor.pngData(from: data) else { return nil }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("pencil-paste-\(fingerprint.suffix(12)).png")
            return (try? png.data.write(to: url, options: .atomic)).map { url.path }
        }
        let capture = ClipboardCapture(kind: .image, imageData: data, date: Date())
        guard let item = ClipboardProcessor.build(capture, fingerprint: fingerprint, disk: disk) else { return nil }
        insert(item) // the watcher's own pass over this copy then finds it and just promotes it
        return (store.item(fingerprint: fingerprint).flatMap { disk.blobURL($0.imageFile, of: $0.id) })?.path
    }

    /// A capture that joined a burst: saved as its own item, tagged with the batch.
    func ingestBatchFile(_ url: URL, batchID: String) {
        guard started, !watcher.isPaused else { return }
        handle(ClipboardCapture(kind: .file, fileURLs: [url], date: Date()), batchID: batchID)
    }

    private func handle(_ capture: ClipboardCapture, batchID: String? = nil) {
        let disk = self.disk
        work.async {
            let fingerprint = ClipboardProcessor.fingerprint(capture)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // (The controller is a singleton; capturing it strongly is fine.)
                    // Already in the history: move it up without writing anything.
                    if let existing = self.store.item(fingerprint: fingerprint) {
                        self.store.promote(id: existing.id, at: capture.date)
                        if let batchID { self.store.setBatch(id: existing.id, batchID) }
                        self.changed()
                        return
                    }
                    self.work.async {
                        var item = ClipboardProcessor.build(capture, fingerprint: fingerprint, disk: disk)
                        item?.batchID = batchID
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated { if let item { self.insert(item) } }
                        }
                    }
                }
            }
        }
    }

    private func insert(_ item: ClipboardItem) {
        switch store.add(item) {
        case .promoted(let existingID):
            // The same content arrived twice in quick succession; drop the second copy's blobs,
            // but keep a burst tag if the second copy had one.
            if let batchID = item.batchID { store.setBatch(id: existingID, batchID) }
            deleteBlobs(of: [item])
        case .inserted(let pruned):
            deleteBlobs(of: pruned)
            if item.kind == .file, item.thumbnailFile == nil { generateFileThumbnail(for: item) }
            runOCR(on: item, backfill: false)
        }
        changed()
    }

    // MARK: Near-identical images

    private let hashQueue = DispatchQueue(label: "pencil.clipboard.hash", qos: .background)

    /// Items saved before perceptual hashing existed get a hash in the background, so
    /// near-identical screenshots fold into one folder. Results land in small batches.
    private func backfillImageHashes() {
        let todo = store.items.filter { $0.imageHash == nil && $0.pixelWidth != nil && !$0.isVideo
            && ($0.kind == .image || ($0.kind == .file && $0.filePaths.count == 1)) }
        guard !todo.isEmpty else { return }
        let disk = self.disk
        hashQueue.async {
            var pending: [(String, String)] = []
            func flush() {
                let batch = pending
                pending = []
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        let history = ClipboardHistoryController.shared
                        for (id, hash) in batch {
                            guard var item = history.store.item(id: id) else { continue }
                            item.imageHash = hash
                            history.store.update(item)
                        }
                        history.changed()
                    }
                }
            }
            for item in todo {
                let url = item.kind == .image ? disk.blobURL(item.imageFile, of: item.id)
                                              : item.filePaths.first.map { URL(fileURLWithPath: $0) }
                if let url, let hash = ClipboardProcessor.imageHash(at: url) { pending.append((item.id, hash)) }
                if pending.count >= 25 { flush() }
            }
            if !pending.isEmpty { flush() }
        }
    }

    // MARK: Text in images

    /// Older items (from before OCR, or whose OCR was interrupted) get it in the background.
    private func backfillOCR() {
        for item in store.items where item.isOCRCandidate && item.ocrText == nil {
            runOCR(on: item, backfill: true)
        }
    }

    private func runOCR(on item: ClipboardItem, backfill: Bool) {
        guard item.isOCRCandidate, item.ocrText == nil else { return }
        let url: URL?
        switch item.kind {
        case .image: url = disk.blobURL(item.imageFile, of: item.id)
        case .file: url = item.filePaths.first.map { URL(fileURLWithPath: $0) }
        case .text: url = nil
        }
        guard let url else { return }
        let id = item.id
        ocr.recognize(url, backfill: backfill) { text in
            guard let text else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let history = ClipboardHistoryController.shared
                    guard var updated = history.store.item(id: id) else { return }
                    updated.ocrText = text
                    updated.storedBytes += Int64(text.utf8.count)
                    history.store.update(updated)
                    history.changed()
                }
            }
        }
    }

    /// Videos, PDFs and other files: a Quick Look thumbnail, stored as the item's thumb.png.
    private func generateFileThumbnail(for item: ClipboardItem) {
        guard let path = item.filePaths.first else { return }
        let disk = self.disk, id = item.id
        ClipboardThumbnails.quickLookPNG(URL(fileURLWithPath: path)) { [weak self] png in
            guard let png else { return }
            self?.work.async {
                guard let size = try? disk.writeBlob(png, named: "thumb.png", for: id) else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, var updated = self.store.item(id: id) else {
                            // Deleted meanwhile.
                            self?.work.async { disk.removeFolder(for: id) }
                            return
                        }
                        updated.thumbnailFile = "thumb.png"
                        updated.storedBytes += size
                        self.store.update(updated)
                        self.changed()
                    }
                }
            }
        }
    }

    private func deleteBlobs(of items: [ClipboardItem]) {
        guard !items.isEmpty else { return }
        let disk = self.disk, ids = items.map(\.id)
        work.async { ids.forEach(disk.removeFolder(for:)) }
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.saveScheduled = false
                let items = self.store.items, disk = self.disk
                self.work.async {
                    do { try disk.save(items) } catch { NSLog("Pencil: clipboard index save failed: \(error)") }
                }
            }
        }
    }

    // MARK: Actions (from the panel)

    enum CopyResult { case copied, missingFiles, notFound }

    /// Makes an item the current clipboard: writes it back and moves it to the top.
    @discardableResult
    func copy(id: String) -> CopyResult {
        guard let item = store.item(id: id) else { return .notFound }
        guard writeToPasteboard(item) else { return .missingFiles }
        store.promote(id: id, at: Date())
        changed()
        return .copied
    }

    /// Makes a whole burst the current clipboard: all its files on the pasteboard as
    /// separate items (capture order), the group moved to the top.
    @discardableResult
    func copyBatch(_ batchID: String) -> CopyResult {
        let members = store.batchItems(batchID)
        guard !members.isEmpty else { return .notFound }
        let urls: [URL] = members.compactMap { m in
            if let path = m.filePaths.first(where: { FileManager.default.fileExists(atPath: $0) }) {
                return URL(fileURLWithPath: path)
            }
            return disk.blobURL(m.imageFile, of: m.id)
        }
        let items = CaptureBatch.pasteboardItems(for: urls)
        guard !items.isEmpty else { return .missingFiles }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(items)
        watcher.ignoreCurrentChange()
        store.promoteBatch(batchID, at: Date())
        CaptureBatch.shared.setLast(id: batchID, urls: urls)
        changed()
        return .copied
    }

    private func writeToPasteboard(_ item: ClipboardItem) -> Bool {
        let result = ClipboardProcessor.write(item, disk: disk)
        // Our own write must not come back as a new history entry.
        watcher.ignoreCurrentChange()
        return result == .written
    }

    /// Deletes an item. Deleting the current clipboard also takes it off the pasteboard
    /// (the next item becomes current), so a mistakenly copied secret really goes away.
    func delete(id: String) {
        let wasCurrent = store.current?.id == id
        guard let removed = store.remove(id: id) else { return }
        deleteBlobs(of: [removed])
        if wasCurrent { syncPasteboardToTop() }
        changed()
    }

    func togglePin(id: String) {
        guard let item = store.item(id: id) else { return }
        store.setPinned(id: id, !item.isPinned)
        changed()
    }

    /// Removes every unpinned item. The pasteboard follows the new top (or is cleared).
    func clearHistory() {
        let oldTop = store.current?.id
        let removed = store.clearUnpinned()
        deleteBlobs(of: removed)
        if store.current?.id != oldTop { syncPasteboardToTop() }
        changed()
    }

    /// Drag-reorder: moves the item so it sits just before `store.items[before]` (in the
    /// order before the move; `before == count` means the end). 0 makes it current.
    func move(id: String, before: Int) {
        guard let from = store.index(of: id) else { return }
        let destination = from < before ? before - 1 : before
        if store.move(id: id, to: destination) { syncPasteboardToTop() }
        changed()
    }

    private func syncPasteboardToTop() {
        if let top = store.current {
            if writeToPasteboard(top) {
                store.promote(id: top.id, at: Date())
            }
        } else {
            NSPasteboard.general.clearContents()
            watcher.ignoreCurrentChange()
        }
    }

    // MARK: Drag out

    /// What a row (or the current card) carries when dragged into another app: a file
    /// URL for images and files (chat apps and Finder take the file), the text for text,
    /// plus the private row id for reordering inside the panel.
    func dragPasteboardItem(for item: ClipboardItem) -> NSPasteboardItem {
        let pb = NSPasteboardItem()
        pb.setString(item.id, forType: Self.rowDragType)
        switch item.kind {
        case .image:
            if let url = disk.blobURL(item.imageFile, of: item.id) {
                pb.setString(url.absoluteString, forType: .fileURL)
            }
        case .file:
            if let path = item.filePaths.first(where: { FileManager.default.fileExists(atPath: $0) }) {
                pb.setString(URL(fileURLWithPath: path).absoluteString, forType: .fileURL)
            }
        case .text:
            let full = disk.blobURL(item.fullTextFile, of: item.id).flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            pb.setString(full ?? item.text ?? "", forType: .string)
        }
        return pb
    }

    /// The full text of a text item (long text lives in a blob).
    func fullText(of item: ClipboardItem) -> String {
        disk.blobURL(item.fullTextFile, of: item.id).flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            ?? item.text ?? ""
    }
}
