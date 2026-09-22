import CoreGraphics
import Foundation

/// Perceptual image hash (dHash): 64 bits from an 9×8 grayscale downsample, one bit per
/// horizontally adjacent pixel pair ("is the left one brighter?"). Screenshots of the same
/// area that differ by a few bytes (or a few pixels) land within a small Hamming distance.
public enum ClipboardImageHash {
    public static let width = 9
    public static let height = 8

    /// dHash of a 9×8 grayscale buffer (row-major, `width * height` bytes).
    public static func dHash(gray: [UInt8]) -> UInt64 {
        precondition(gray.count == width * height, "expected a 9×8 grayscale buffer")
        var hash: UInt64 = 0
        var bit: UInt64 = 1
        for y in 0..<height {
            for x in 0..<(width - 1) {
                if gray[y * width + x] > gray[y * width + x + 1] { hash |= bit }
                bit <<= 1
            }
        }
        return hash
    }

    /// Downsamples `image` to 9×8 grayscale (high-quality interpolation) and hashes it.
    public static func dHash(_ image: CGImage) -> UInt64? {
        var pixels = [UInt8](repeating: 0, count: width * height)
        let ok = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .high
            // Transparent areas read as white, like on a light background.
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? dHash(gray: pixels) : nil
    }

    public static func hamming(_ a: UInt64, _ b: UInt64) -> Int { (a ^ b).nonzeroBitCount }

    public static func hex(_ hash: UInt64) -> String { String(format: "%016llx", hash) }
    public static func parse(_ hex: String?) -> UInt64? { hex.flatMap { UInt64($0, radix: 16) } }
}

/// When two history items count as "the same" and share a folder.
public enum ClipboardSimilarity {
    /// Pixel dimensions may differ by this much (a region picked by hand twice).
    public static let sizeTolerance = 2
    /// dHash bits that may differ.
    public static let maxHashDistance = 6

    /// Images (and image files) with near-equal sizes and near-equal perceptual hashes.
    public static func imagesSimilar(width w1: Int, height h1: Int, hash a: UInt64,
                                     width w2: Int, height h2: Int, hash b: UInt64) -> Bool {
        abs(w1 - w2) <= sizeTolerance && abs(h1 - h2) <= sizeTolerance
            && ClipboardImageHash.hamming(a, b) <= maxHashDistance
    }

    /// Items compared by picture: images, and single image files (Pencil captures).
    static func imageSignature(_ item: ClipboardItem) -> (w: Int, h: Int, hash: UInt64)? {
        guard item.kind == .image || (item.kind == .file && item.filePaths.count == 1 && !item.isVideo),
              let w = item.pixelWidth, let h = item.pixelHeight,
              let hash = ClipboardImageHash.parse(item.imageHash) else { return nil }
        return (w, h, hash)
    }

    /// Exact-match key for text (trimmed) and non-image files (the path set). nil = compare
    /// by picture, or don't group.
    static func exactKey(_ item: ClipboardItem) -> String? {
        switch item.kind {
        case .text:
            let t = (item.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : "text:" + t
        case .file:
            return item.filePaths.isEmpty ? nil : "files:" + item.filePaths.sorted().joined(separator: "\n")
        case .image:
            return nil
        }
    }

    public static func similar(_ a: ClipboardItem, _ b: ClipboardItem) -> Bool {
        if let sa = imageSignature(a), let sb = imageSignature(b) {
            return imagesSimilar(width: sa.w, height: sa.h, hash: sa.hash, width: sb.w, height: sb.h, hash: sb.hash)
        }
        if let ka = exactKey(a), let kb = exactKey(b) { return ka == kb }
        return false
    }
}

/// A folder in the history list: a burst (items sharing a batch id) or items that are
/// "the same" (ClipboardSimilarity). Members are in list order, newest first.
public struct ClipboardGroup: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case burst(batchID: String)
        case similar
    }

    public var kind: Kind
    public var items: [ClipboardItem]

    /// Stable across new copies joining: bursts by batch id, similar folders by their
    /// oldest member (the newest one changes every time the same thing is copied again).
    public var key: String {
        switch kind {
        case .burst(let id): return "burst:" + id
        case .similar: return "similar:" + (items.last?.id ?? "")
        }
    }

    /// The member that stands for the folder: its title, its paste.
    public var newest: ClipboardItem { items[0] }
    public var isBurst: Bool { if case .burst = kind { return true }; return false }
}

/// One entry in the history list: a single item, or a folder.
public enum ClipboardListEntry: Equatable, Sendable {
    case single(ClipboardItem)
    case group(ClipboardGroup)

    public var key: String {
        switch self {
        case .single(let item): return item.id
        case .group(let g): return g.key
        }
    }

    /// The newest item (a single item, or the folder's newest member).
    public var newest: ClipboardItem {
        switch self {
        case .single(let item): return item
        case .group(let g): return g.newest
        }
    }

    public var items: [ClipboardItem] {
        switch self {
        case .single(let item): return [item]
        case .group(let g): return g.items
        }
    }
}

public enum ClipboardGrouping {
    /// Groups the history into folders wherever the members sit: items sharing a batch
    /// id, and items that are "the same". A folder takes the position of its newest
    /// member (its first appearance in `items`, which is newest first); a group of one
    /// is a plain row. Image similarity compares against each folder's newest member.
    public static func entries(_ items: [ClipboardItem]) -> [ClipboardListEntry] {
        var groups: [(kind: ClipboardGroup.Kind, members: [ClipboardItem])] = []
        var byBurst: [String: Int] = [:]
        var byKey: [String: Int] = [:]
        var imageGroups: [(group: Int, w: Int, h: Int, hash: UInt64)] = []

        for item in items {
            if let batch = item.batchID {
                if let g = byBurst[batch] { groups[g].members.append(item) } else {
                    byBurst[batch] = groups.count
                    groups.append((.burst(batchID: batch), [item]))
                }
                continue
            }
            if let sig = ClipboardSimilarity.imageSignature(item) {
                if let match = imageGroups.first(where: {
                    ClipboardSimilarity.imagesSimilar(width: $0.w, height: $0.h, hash: $0.hash,
                                                      width: sig.w, height: sig.h, hash: sig.hash)
                }) {
                    groups[match.group].members.append(item)
                } else {
                    imageGroups.append((groups.count, sig.w, sig.h, sig.hash))
                    groups.append((.similar, [item]))
                }
                continue
            }
            if let key = ClipboardSimilarity.exactKey(item) {
                if let g = byKey[key] { groups[g].members.append(item) } else {
                    byKey[key] = groups.count
                    groups.append((.similar, [item]))
                }
                continue
            }
            groups.append((.similar, [item]))
        }
        return groups.map { g in
            g.members.count >= 2 ? .group(ClipboardGroup(kind: g.kind, items: g.members)) : .single(g.members[0])
        }
    }
}
