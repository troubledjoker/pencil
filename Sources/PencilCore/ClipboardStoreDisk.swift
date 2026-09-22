import Foundation

/// The history on disk:
///
///     <root>/index.json          ClipboardIndex (order, metadata, short text)
///     <root>/items/<id>/...      that item's blobs: image PNG, thumbnail, RTF, long text
///
/// Each item owns one folder, so deleting or pruning an item is one directory removal.
/// Thread-safe: it holds no mutable state; callers serialize writes to the same item.
public struct ClipboardStoreDisk: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// ~/Library/Application Support/Pencil/Clipboard
    public static var defaultRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Pencil", isDirectory: true)
            .appendingPathComponent("Clipboard", isDirectory: true)
    }

    public var indexURL: URL { root.appendingPathComponent("index.json") }
    public var itemsURL: URL { root.appendingPathComponent("items", isDirectory: true) }

    public func folder(for id: String) -> URL {
        itemsURL.appendingPathComponent(id, isDirectory: true)
    }

    /// The URL of a blob that belongs to an item (nil name → nil).
    public func blobURL(_ name: String?, of id: String) -> URL? {
        guard let name, !name.isEmpty else { return nil }
        return folder(for: id).appendingPathComponent(name)
    }

    // MARK: Index

    /// The saved items, or [] if there's no index yet. A corrupt index is moved aside
    /// (index.corrupt-<time>.json) rather than silently overwritten.
    public func loadItems() -> [ClipboardItem] {
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        do {
            let index = try ClipboardIndex.decode(data)
            // Drop entries whose blobs vanished (the image is the item).
            return index.items.filter { item in
                guard item.kind == .image, let url = blobURL(item.imageFile, of: item.id) else { return true }
                return FileManager.default.fileExists(atPath: url.path)
            }
        } catch {
            let aside = root.appendingPathComponent("index.corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: indexURL, to: aside)
            return []
        }
    }

    public func save(_ items: [ClipboardItem]) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try ClipboardIndex(items: items).encoded()
        try data.write(to: indexURL, options: .atomic)
    }

    // MARK: Blobs

    /// Writes one blob into the item's folder and returns its size in bytes.
    @discardableResult
    public func writeBlob(_ data: Data, named name: String, for id: String) throws -> Int64 {
        let dir = folder(for: id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: dir.appendingPathComponent(name), options: .atomic)
        return Int64(data.count)
    }

    public func removeFolder(for id: String) {
        try? FileManager.default.removeItem(at: folder(for: id))
    }

    /// Total bytes of everything in the item's folder.
    public func folderSize(for id: String) -> Int64 {
        let dir = folder(for: id)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return 0 }
        return names.reduce(0) { total, name in
            let attrs = try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(name).path)
            return total + ((attrs?[.size] as? NSNumber)?.int64Value ?? 0)
        }
    }

    /// Deletes item folders that no index entry refers to (left by a crash mid-save,
    /// or by a delete whose index save didn't land). Returns the removed ids.
    @discardableResult
    public func removeOrphans(keeping ids: Set<String>) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: itemsURL.path) else { return [] }
        let orphans = names.filter { !$0.hasPrefix(".") && !ids.contains($0) }
        orphans.forEach(removeFolder(for:))
        return orphans
    }
}
