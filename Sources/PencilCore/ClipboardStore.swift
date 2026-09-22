import Foundation

/// One saved clipboard entry. Plain data: the app target reads and writes the
/// pasteboard and the blobs; this only describes what was copied.
public struct ClipboardItem: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case text, image, file
    }

    public var id: String
    public var kind: Kind
    /// Content identity used for de-duplication (e.g. "text:<sha>", "files:<paths>").
    public var fingerprint: String
    /// When this content was first saved.
    public var firstCopiedAt: Date
    /// When it last became the current clipboard (copied again, or picked from the history).
    public var copiedAt: Date
    public var isPinned: Bool

    // Text
    /// The text (kind .text). Long text keeps only a prefix here; the rest is in `fullTextFile`.
    public var text: String?
    /// Name of the full-text blob inside the item's folder, when `text` is only a prefix.
    public var fullTextFile: String?
    /// Name of the RTF blob inside the item's folder, if rich text was kept.
    public var richTextFile: String?

    // Image
    /// Name of the PNG blob inside the item's folder (kind .image).
    public var imageFile: String?
    /// Name of the thumbnail PNG inside the item's folder (images and files).
    public var thumbnailFile: String?
    public var pixelWidth: Int?
    public var pixelHeight: Int?

    // Files
    /// Absolute paths. For .file items these are the copied files; for an .image item
    /// it's the image's original file if the pasteboard carried one (Pencil snapshots do).
    public var filePaths: [String]
    /// A human type name for the (first) file, e.g. "PNG image", "MPEG-4 movie".
    public var fileTypeName: String?
    /// The UTI of the (first) file, e.g. "public.png".
    public var fileTypeIdentifier: String?
    public var fileSize: Int64?
    public var isVideo: Bool

    /// Text recognized in the image (image items and image files) by OCR.
    /// nil = not processed yet; "" = processed, no text found.
    public var ocrText: String?

    /// Perceptual hash (dHash, 16 hex digits) for images and image files, used to fold
    /// near-identical copies into one folder. nil = not computed yet.
    public var imageHash: String?

    /// Bytes this item keeps on disk in its own folder (blobs + thumbnail + inline text).
    public var storedBytes: Int64

    /// Set for items captured together in one burst; they show as one grouped row.
    public var batchID: String?

    public init(id: String = UUID().uuidString, kind: Kind, fingerprint: String,
                copiedAt: Date, firstCopiedAt: Date? = nil, isPinned: Bool = false,
                text: String? = nil, fullTextFile: String? = nil, richTextFile: String? = nil,
                imageFile: String? = nil, thumbnailFile: String? = nil,
                pixelWidth: Int? = nil, pixelHeight: Int? = nil,
                filePaths: [String] = [], fileTypeName: String? = nil, fileTypeIdentifier: String? = nil,
                fileSize: Int64? = nil, isVideo: Bool = false, ocrText: String? = nil, storedBytes: Int64 = 0,
                batchID: String? = nil, imageHash: String? = nil) {
        self.id = id
        self.kind = kind
        self.fingerprint = fingerprint
        self.copiedAt = copiedAt
        self.firstCopiedAt = firstCopiedAt ?? copiedAt
        self.isPinned = isPinned
        self.text = text
        self.fullTextFile = fullTextFile
        self.richTextFile = richTextFile
        self.imageFile = imageFile
        self.thumbnailFile = thumbnailFile
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.filePaths = filePaths
        self.fileTypeName = fileTypeName
        self.fileTypeIdentifier = fileTypeIdentifier
        self.fileSize = fileSize
        self.isVideo = isVideo
        self.ocrText = ocrText
        self.storedBytes = storedBytes
        self.batchID = batchID
        self.imageHash = imageHash
    }

    // Tolerant decoding: fields added later default instead of failing the whole index.
    private enum CodingKeys: String, CodingKey {
        case id, kind, fingerprint, firstCopiedAt, copiedAt, isPinned, text, fullTextFile, richTextFile,
             imageFile, thumbnailFile, pixelWidth, pixelHeight, filePaths, fileTypeName, fileTypeIdentifier,
             fileSize, isVideo, ocrText, storedBytes, batchID, imageHash
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(Kind.self, forKey: .kind)
        fingerprint = try c.decode(String.self, forKey: .fingerprint)
        copiedAt = try c.decode(Date.self, forKey: .copiedAt)
        firstCopiedAt = try c.decodeIfPresent(Date.self, forKey: .firstCopiedAt) ?? copiedAt
        isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        text = try c.decodeIfPresent(String.self, forKey: .text)
        fullTextFile = try c.decodeIfPresent(String.self, forKey: .fullTextFile)
        richTextFile = try c.decodeIfPresent(String.self, forKey: .richTextFile)
        imageFile = try c.decodeIfPresent(String.self, forKey: .imageFile)
        thumbnailFile = try c.decodeIfPresent(String.self, forKey: .thumbnailFile)
        pixelWidth = try c.decodeIfPresent(Int.self, forKey: .pixelWidth)
        pixelHeight = try c.decodeIfPresent(Int.self, forKey: .pixelHeight)
        filePaths = try c.decodeIfPresent([String].self, forKey: .filePaths) ?? []
        fileTypeName = try c.decodeIfPresent(String.self, forKey: .fileTypeName)
        fileTypeIdentifier = try c.decodeIfPresent(String.self, forKey: .fileTypeIdentifier)
        fileSize = try c.decodeIfPresent(Int64.self, forKey: .fileSize)
        isVideo = try c.decodeIfPresent(Bool.self, forKey: .isVideo) ?? false
        ocrText = try c.decodeIfPresent(String.self, forKey: .ocrText)
        storedBytes = try c.decodeIfPresent(Int64.self, forKey: .storedBytes) ?? 0
        batchID = try c.decodeIfPresent(String.self, forKey: .batchID)
        imageHash = try c.decodeIfPresent(String.self, forKey: .imageHash)
    }

    // MARK: Display

    public var fileNames: [String] { filePaths.map { ($0 as NSString).lastPathComponent } }

    /// One line for a list row: the text's first non-empty line, the file name(s), or the image size.
    public var title: String {
        switch kind {
        case .text:
            let line = (text ?? "").split(whereSeparator: \.isNewline)
                .lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
            return line.count > 160 ? String(line.prefix(160)) + "…" : line
        case .file:
            let names = fileNames
            guard let first = names.first else { return "File" }
            return names.count == 1 ? first : "\(first) + \(names.count - 1) more"
        case .image:
            if let name = fileNames.first { return name }
            if let w = pixelWidth, let h = pixelHeight { return "Image \(w) × \(h)" }
            return "Image"
        }
    }

    /// What search matches against: the text, file names, type, and text found in the image.
    public var searchText: String {
        [searchTextWithoutOCR, ocrText ?? ""].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// Everything searchable except OCR text (to tell when a match came only from the image).
    public var searchTextWithoutOCR: String {
        var parts: [String] = []
        if let text { parts.append(text) }
        parts.append(contentsOf: fileNames)
        if let fileTypeName { parts.append(fileTypeName) }
        if kind == .image { parts.append("image") }
        return parts.joined(separator: "\n")
    }

    /// Whether OCR can run on this item: stored images, and image files (Pencil snapshots).
    public var isOCRCandidate: Bool {
        switch kind {
        case .image: return imageFile != nil
        case .file: return filePaths.count == 1 && pixelWidth != nil && !isVideo
        case .text: return false
        }
    }

    /// True if every word of `query` is found (case- and diacritic-insensitive).
    public func matches(_ query: String) -> Bool {
        Self.contains(searchText, words: Self.words(query))
    }

    /// True if the item matches `query` only thanks to the text found in its image (without
    /// the OCR text, at least one word wouldn't be found). Drives the "text in image" note.
    public func matchesOnlyInImageText(_ query: String) -> Bool {
        let w = Self.words(query)
        guard !w.isEmpty, let ocr = ocrText, !ocr.isEmpty else { return false }
        return Self.contains(searchText, words: w) && !Self.contains(searchTextWithoutOCR, words: w)
    }

    static func words(_ query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    static func contains(_ haystack: String, words: [String]) -> Bool {
        words.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}

/// The ordered history: index 0 is the current clipboard, then most recent first.
/// Order is also the user's order: rows can be dragged, and pruning takes from the end.
public struct ClipboardStore: Equatable, Sendable {
    public static let defaultMaxCount = 1000
    public static let defaultMaxBytes: Int64 = 2 * 1024 * 1024 * 1024
    /// Rows shown before the first "Show more".
    public static let initialVisibleCount = 10
    /// Rows each "Show more" (or scrolling to the end) adds.
    public static let pageSize = 50

    public private(set) var items: [ClipboardItem]
    public var maxCount: Int
    public var maxBytes: Int64

    public init(items: [ClipboardItem] = [], maxCount: Int = ClipboardStore.defaultMaxCount,
                maxBytes: Int64 = ClipboardStore.defaultMaxBytes) {
        self.items = items
        self.maxCount = maxCount
        self.maxBytes = maxBytes
    }

    public var current: ClipboardItem? { items.first }
    public var count: Int { items.count }
    public var totalBytes: Int64 { items.reduce(0) { $0 + $1.storedBytes } }

    public func index(of id: String) -> Int? { items.firstIndex { $0.id == id } }
    public func item(id: String) -> ClipboardItem? { items.first { $0.id == id } }
    public func item(fingerprint: String) -> ClipboardItem? { items.first { $0.fingerprint == fingerprint } }

    public enum AddResult: Equatable, Sendable {
        /// A new item went to the top. `pruned` were dropped to stay within the limits;
        /// their blobs should be deleted.
        case inserted(pruned: [ClipboardItem])
        /// The same content was already in the history; that item moved to the top instead.
        /// The new item was not added, so its blobs (if any were written) should be deleted.
        case promoted(existingID: String)
    }

    /// Adds newly copied content: a duplicate (same fingerprint) moves to the top,
    /// anything else is inserted at the top and the history is pruned.
    public mutating func add(_ item: ClipboardItem) -> AddResult {
        if let existing = self.item(fingerprint: item.fingerprint) {
            promote(id: existing.id, at: item.copiedAt)
            return .promoted(existingID: existing.id)
        }
        items.insert(item, at: 0)
        return .inserted(pruned: prune())
    }

    /// Makes an item the current clipboard: moves it to the top and stamps `copiedAt`.
    @discardableResult
    public mutating func promote(id: String, at date: Date) -> Bool {
        guard let i = index(of: id) else { return false }
        var item = items.remove(at: i)
        item.copiedAt = date
        items.insert(item, at: 0)
        return true
    }

    /// Moves an item to `destination` (an index in the final order, clamped).
    /// Returns true if the top item (the current clipboard) changed.
    @discardableResult
    public mutating func move(id: String, to destination: Int) -> Bool {
        guard let from = index(of: id) else { return false }
        let oldTop = items.first?.id
        let item = items.remove(at: from)
        let to = min(max(destination, 0), items.count)
        items.insert(item, at: to)
        return items.first?.id != oldTop
    }

    @discardableResult
    public mutating func remove(id: String) -> ClipboardItem? {
        guard let i = index(of: id) else { return nil }
        return items.remove(at: i)
    }

    public mutating func setPinned(id: String, _ pinned: Bool) {
        guard let i = index(of: id) else { return }
        items[i].isPinned = pinned
    }

    /// Clears the history. Pinned items stay. Returns what was removed.
    public mutating func clearUnpinned() -> [ClipboardItem] {
        let removed = items.filter { !$0.isPinned }
        items.removeAll { !$0.isPinned }
        return removed
    }

    /// Drops the oldest unpinned items (from the end of the list) until the history is
    /// within `maxCount` and `maxBytes`. Pinned items and the current clipboard (index 0)
    /// are never pruned, so the limits can be exceeded by those alone.
    @discardableResult
    public mutating func prune() -> [ClipboardItem] {
        var removed: [ClipboardItem] = []
        var bytes = totalBytes
        var i = items.count - 1
        while i >= 1, items.count > maxCount || bytes > maxBytes {
            if !items[i].isPinned {
                let gone = items.remove(at: i)
                bytes -= gone.storedBytes
                removed.append(gone)
            }
            i -= 1
        }
        return removed
    }

    /// Items whose text, file names, type or image text (OCR) contain every word of `query`
    /// (case- and diacritic-insensitive), in history order. An empty query matches all.
    public func filtered(_ query: String) -> [ClipboardItem] {
        let words = ClipboardItem.words(query)
        guard !words.isEmpty else { return items }
        return items.filter { ClipboardItem.contains($0.searchText, words: words) }
    }

    /// How many rows to show after a "Show more", given how many are shown now.
    public static func visibleCount(afterShowingMore current: Int, total: Int) -> Int {
        min(total, max(current, initialVisibleCount) + pageSize)
    }

    // MARK: Batches (bursts)

    /// A batch's items in capture order (oldest first): the order they go on the pasteboard.
    public func batchItems(_ batchID: String) -> [ClipboardItem] {
        items.filter { $0.batchID == batchID }.sorted { $0.firstCopiedAt < $1.firstCopiedAt }
    }

    /// Makes a whole batch the current clipboard: its items move to the top, newest first
    /// (the same order they had), everything else keeps its order.
    @discardableResult
    public mutating func promoteBatch(_ batchID: String, at date: Date) -> Bool {
        let members = items.filter { $0.batchID == batchID }
        guard !members.isEmpty else { return false }
        items.removeAll { $0.batchID == batchID }
        items.insert(contentsOf: members.map { var m = $0; m.copiedAt = date; return m }, at: 0)
        return true
    }

    /// Tags an existing item as part of a batch (e.g. a snapshot that joined a burst).
    public mutating func setBatch(id: String, _ batchID: String?) {
        guard let i = index(of: id) else { return }
        items[i].batchID = batchID
    }

    /// Replaces an item's data in place (same id), e.g. after a thumbnail was generated.
    public mutating func update(_ item: ClipboardItem) {
        guard let i = index(of: item.id) else { return }
        items[i] = item
    }
}

/// The on-disk index file.
public struct ClipboardIndex: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var version: Int
    public var items: [ClipboardItem]

    public init(items: [ClipboardItem]) {
        version = Self.currentVersion
        self.items = items
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return try e.encode(self)
    }

    public static func decode(_ data: Data) throws -> ClipboardIndex {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(ClipboardIndex.self, from: data)
    }
}
