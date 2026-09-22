import CoreGraphics
import XCTest
@testable import PencilCore

final class ClipboardStoreSimilarityTests: XCTestCase {
    // MARK: Test images

    /// A w×h RGBA image drawn by `draw` (a "screenshot" with some shapes on it).
    private func image(_ w: Int, _ h: Int, _ draw: (CGContext) -> Void) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 0.95, green: 0.95, blue: 0.95, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        draw(ctx)
        return ctx.makeImage()!
    }

    private func windowShot(_ w: Int = 120, _ h: Int = 80, tweak: ((CGContext) -> Void)? = nil) -> CGImage {
        image(w, h) { ctx in
            ctx.setFillColor(red: 0.1, green: 0.3, blue: 0.8, alpha: 1)
            ctx.fill(CGRect(x: 0, y: CGFloat(h) * 0.8, width: CGFloat(w), height: CGFloat(h) * 0.2)) // title bar
            ctx.setFillColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1)
            ctx.fill(CGRect(x: CGFloat(w) * 0.1, y: CGFloat(h) * 0.2, width: CGFloat(w) * 0.35, height: CGFloat(h) * 0.4))
            ctx.setFillColor(red: 0.9, green: 0.4, blue: 0.1, alpha: 1)
            ctx.fillEllipse(in: CGRect(x: CGFloat(w) * 0.6, y: CGFloat(h) * 0.15, width: CGFloat(w) * 0.3, height: CGFloat(h) * 0.5))
            tweak?(ctx)
        }
    }

    private func hash(_ img: CGImage) -> UInt64 { ClipboardImageHash.dHash(img)! }

    // MARK: dHash

    func testDHashOfGrayBuffer() {
        // Every row falls left to right: all 64 bits set.
        let falling = (0..<8).flatMap { _ in (0..<9).map { UInt8(200 - $0 * 20) } }
        XCTAssertEqual(ClipboardImageHash.dHash(gray: falling), UInt64.max)
        let flat = [UInt8](repeating: 128, count: 72)
        XCTAssertEqual(ClipboardImageHash.dHash(gray: flat), 0)
    }

    func testIdenticalImagesHashTheSame() {
        XCTAssertEqual(hash(windowShot()), hash(windowShot()))
    }

    func testOnePixelChangeStaysWithinDistance() {
        let a = hash(windowShot())
        let b = hash(windowShot { ctx in
            ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
            ctx.fill(CGRect(x: 30, y: 30, width: 1, height: 1))
        })
        XCTAssertLessThanOrEqual(ClipboardImageHash.hamming(a, b), ClipboardSimilarity.maxHashDistance)
        XCTAssertTrue(ClipboardSimilarity.imagesSimilar(width: 120, height: 80, hash: a, width: 120, height: 80, hash: b))
    }

    func testDifferentImageIsFarApart() {
        let a = hash(windowShot())
        let other = hash(image(120, 80) { ctx in
            // Vertical stripes: nothing like the window.
            for x in stride(from: 0, to: 120, by: 20) {
                ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
                ctx.fill(CGRect(x: x, y: 0, width: 10, height: 80))
            }
        })
        XCTAssertGreaterThan(ClipboardImageHash.hamming(a, other), ClipboardSimilarity.maxHashDistance)
        XCTAssertFalse(ClipboardSimilarity.imagesSimilar(width: 120, height: 80, hash: a, width: 120, height: 80, hash: other))
    }

    func testSizesMustBeWithinTwoPixels() {
        let h = hash(windowShot())
        XCTAssertTrue(ClipboardSimilarity.imagesSimilar(width: 120, height: 80, hash: h, width: 122, height: 79, hash: h))
        XCTAssertFalse(ClipboardSimilarity.imagesSimilar(width: 120, height: 80, hash: h, width: 123, height: 80, hash: h))
        // The same picture at double size hashes alike but is a different size: not the same.
        let big = hash(windowShot(240, 160))
        XCTAssertLessThanOrEqual(ClipboardImageHash.hamming(h, big), ClipboardSimilarity.maxHashDistance)
        XCTAssertFalse(ClipboardSimilarity.imagesSimilar(width: 120, height: 80, hash: h, width: 240, height: 160, hash: big))
    }

    func testHexRoundTrip() {
        let h: UInt64 = 0xDEAD_BEEF_0123_4567
        XCTAssertEqual(ClipboardImageHash.hex(h), "deadbeef01234567")
        XCTAssertEqual(ClipboardImageHash.parse(ClipboardImageHash.hex(h)), h)
        XCTAssertEqual(ClipboardImageHash.parse(ClipboardImageHash.hex(0)), 0)
        XCTAssertNil(ClipboardImageHash.parse(nil))
    }

    // MARK: Rule

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func text(_ id: String, _ s: String) -> ClipboardItem {
        ClipboardItem(id: id, kind: .text, fingerprint: "text:" + s, copiedAt: t0, text: s)
    }

    private func img(_ id: String, _ w: Int, _ h: Int, _ hash: UInt64?, file: String? = nil) -> ClipboardItem {
        ClipboardItem(id: id, kind: file == nil ? .image : .file, fingerprint: id, copiedAt: t0,
                      imageFile: file == nil ? "a.png" : nil, pixelWidth: w, pixelHeight: h,
                      filePaths: file.map { [$0] } ?? [], imageHash: hash.map(ClipboardImageHash.hex))
    }

    func testTextIsTheSameAfterTrimming() {
        XCTAssertTrue(ClipboardSimilarity.similar(text("a", "hello "), text("b", "\nhello")))
        XCTAssertFalse(ClipboardSimilarity.similar(text("a", "hello"), text("b", "Hello")))
        XCTAssertFalse(ClipboardSimilarity.similar(text("a", "  "), text("b", "")), "blank text never groups")
    }

    func testFilesAreTheSameByPathSet() {
        let a = ClipboardItem(id: "a", kind: .file, fingerprint: "a", copiedAt: t0, filePaths: ["/x", "/y"])
        let b = ClipboardItem(id: "b", kind: .file, fingerprint: "b", copiedAt: t0, filePaths: ["/y", "/x"])
        let c = ClipboardItem(id: "c", kind: .file, fingerprint: "c", copiedAt: t0, filePaths: ["/x"])
        XCTAssertTrue(ClipboardSimilarity.similar(a, b))
        XCTAssertFalse(ClipboardSimilarity.similar(a, c))
    }

    func testImagesAndImageFilesCompareByPicture() {
        XCTAssertTrue(ClipboardSimilarity.similar(img("a", 100, 50, 0b1011), img("b", 101, 50, 0b1001)))
        XCTAssertTrue(ClipboardSimilarity.similar(img("a", 100, 50, 7), img("s", 100, 50, 7, file: "/p/shot.png")),
                      "a snapshot file and the same pasted image")
        XCTAssertFalse(ClipboardSimilarity.similar(img("a", 100, 50, 0), img("b", 100, 50, 0xFF)))
        XCTAssertFalse(ClipboardSimilarity.similar(img("a", 100, 50, nil), img("b", 100, 50, nil)),
                       "no hash yet: not grouped")
        XCTAssertFalse(ClipboardSimilarity.similar(img("a", 100, 50, 7), text("t", "image")))
    }

    // MARK: Grouping

    func testSimilarItemsGroupWhereverTheyAreAtTheNewestPosition() {
        let items = [text("t3", "hi"), img("i2", 100, 50, 1), text("x", "other"), text("t1", "hi "),
                     img("i1", 100, 50, 3), text("t0", " hi")]
        let entries = ClipboardGrouping.entries(items)
        XCTAssertEqual(entries.count, 3)
        guard case .group(let hi) = entries[0], case .group(let pics) = entries[1] else { return XCTFail() }
        XCTAssertEqual(hi.items.map(\.id), ["t3", "t1", "t0"])
        XCTAssertEqual(hi.newest.id, "t3", "the newest member stands for the folder")
        XCTAssertEqual(pics.items.map(\.id), ["i2", "i1"])
        XCTAssertEqual(entries[2], .single(items[2]))
    }

    func testSimilarFolderKeyIsStableWhenANewCopyJoins() {
        let before = ClipboardGrouping.entries([text("b", "hi"), text("a", "hi")])
        let after = ClipboardGrouping.entries([text("c", "hi"), text("b", "hi"), text("a", "hi")])
        XCTAssertEqual(before[0].key, after[0].key)
    }

    func testDuplicatesCountAsOneEntry() {
        var items = (0..<5).map { text("dup\($0)", "same") }
        items += (0..<9).map { text("u\($0)", "unique \($0)") }
        let entries = ClipboardGrouping.entries(items)
        XCTAssertEqual(entries.count, 10, "5 copies of the same thing are one folder")
        XCTAssertEqual(entries.prefix(10).flatMap(\.items).count, 14, "every item is still reachable")
    }

    func testImageHashIsBackwardCompatibleJSON() throws {
        let old = #"{"version":1,"items":[{"id":"1","kind":"image","fingerprint":"i","copiedAt":"2026-09-22T10:00:00Z","imageFile":"a.png"}]}"#
        XCTAssertNil(try ClipboardIndex.decode(Data(old.utf8)).items[0].imageHash)
        let back = try ClipboardIndex.decode(ClipboardIndex(items: [img("a", 1, 1, 42)]).encoded())
        XCTAssertEqual(back.items[0].imageHash, ClipboardImageHash.hex(42))
    }
}
