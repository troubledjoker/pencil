import Foundation

/// The rows picked in the sidebar's select mode, by item id, in the order they were picked.
/// Survives searching and reloads; ids that leave the history are dropped with `keep(only:)`.
public struct ClipboardSelection: Equatable, Sendable {
    public private(set) var ids: [String] = []

    /// How much of a folder (or any set of items) is picked.
    public enum State: Equatable, Sendable { case none, some, all }

    public init(_ ids: [String] = []) {
        for id in ids where !self.ids.contains(id) { self.ids.append(id) }
    }

    public var count: Int { ids.count }
    public var isEmpty: Bool { ids.isEmpty }

    public func contains(_ id: String) -> Bool { ids.contains(id) }

    public mutating func toggle(_ id: String) {
        if let i = ids.firstIndex(of: id) { ids.remove(at: i) } else { ids.append(id) }
    }

    public func state(of members: [String]) -> State {
        let picked = members.filter(contains).count
        if picked == 0 { return .none }
        return picked == members.count ? .all : .some
    }

    /// A folder click: all of it picked → none of it; otherwise all of it.
    public mutating func toggleAll(_ members: [String]) {
        if state(of: members) == .all {
            ids.removeAll { members.contains($0) }
        } else {
            for id in members where !contains(id) { ids.append(id) }
        }
    }

    public mutating func keep(only existing: Set<String>) {
        ids.removeAll { !existing.contains($0) }
    }
}

extension ClipboardStore {
    /// Tags the picked items as one batch, so they show as one folder and paste together.
    /// Returns how many were tagged (ids no longer in the history are skipped).
    @discardableResult
    public mutating func group(_ ids: [String], as batchID: String) -> Int {
        var n = 0
        for id in ids where item(id: id) != nil {
            setBatch(id: id, batchID)
            n += 1
        }
        return n
    }
}

public enum ClipboardJoin {
    /// Several text items pasted as one: oldest first, blank line between, blanks dropped.
    public static func text(_ parts: [String]) -> String {
        parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }
}

extension ClipboardFormat {
    /// "3 images, 2 videos, 1 text" for a group on the clipboard.
    public static func groupSummary(_ items: [ClipboardItem]) -> String {
        var images = 0, videos = 0, texts = 0, files = 0
        for item in items {
            switch item.kind {
            case .text: texts += 1
            case .image: images += 1
            case .file where item.isVideo: videos += 1
            case .file where item.pixelWidth != nil && item.filePaths.count == 1: images += 1
            case .file: files += 1
            }
        }
        func part(_ n: Int, _ one: String, _ many: String) -> String? { n == 0 ? nil : "\(n) \(n == 1 ? one : many)" }
        return [part(images, "image", "images"), part(videos, "video", "videos"),
                part(files, "file", "files"), part(texts, "text", "texts")]
            .compactMap { $0 }.joined(separator: ", ")
    }
}
