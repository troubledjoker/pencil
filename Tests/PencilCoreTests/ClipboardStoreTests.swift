import XCTest
@testable import PencilCore

final class ClipboardStoreTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func text(_ s: String, at offset: TimeInterval = 0, bytes: Int64 = 10,
                      pinned: Bool = false) -> ClipboardItem {
        ClipboardItem(id: "id-" + s, kind: .text, fingerprint: "text:" + s, copiedAt: t0.addingTimeInterval(offset),
                      isPinned: pinned, text: s, storedBytes: bytes)
    }

    private func ids(_ store: ClipboardStore) -> [String] { store.items.map { $0.text ?? "" } }

    // MARK: Ordering and dedupe

    func testNewItemsGoOnTopAndTopIsCurrent() {
        var s = ClipboardStore()
        _ = s.add(text("a", at: 1))
        _ = s.add(text("b", at: 2))
        _ = s.add(text("c", at: 3))
        XCTAssertEqual(ids(s), ["c", "b", "a"])
        XCTAssertEqual(s.current?.text, "c")
    }

    func testDuplicateMovesExistingToTopWithoutAdding() {
        var s = ClipboardStore()
        _ = s.add(text("a", at: 1))
        _ = s.add(text("b", at: 2))
        _ = s.add(text("c", at: 3))
        var again = text("a", at: 10)
        again.id = "fresh-id"
        let result = s.add(again)
        XCTAssertEqual(result, .promoted(existingID: "id-a"))
        XCTAssertEqual(ids(s), ["a", "c", "b"])
        XCTAssertEqual(s.count, 3)
        XCTAssertEqual(s.current?.id, "id-a", "the original item is kept, not the new copy")
        XCTAssertEqual(s.current?.copiedAt, t0.addingTimeInterval(10), "copiedAt is refreshed")
        XCTAssertEqual(s.current?.firstCopiedAt, t0.addingTimeInterval(1), "first copy time is kept")
    }

    func testDuplicateKeepsPinState() {
        var s = ClipboardStore()
        _ = s.add(text("a", at: 1))
        s.setPinned(id: "id-a", true)
        _ = s.add(text("b", at: 2))
        _ = s.add(text("a", at: 3))
        XCTAssertEqual(s.current?.isPinned, true)
    }

    func testPromoteMovesToTop() {
        var s = ClipboardStore(items: [text("c"), text("b"), text("a")])
        XCTAssertTrue(s.promote(id: "id-a", at: t0.addingTimeInterval(99)))
        XCTAssertEqual(ids(s), ["a", "c", "b"])
        XCTAssertEqual(s.current?.copiedAt, t0.addingTimeInterval(99))
        XCTAssertFalse(s.promote(id: "missing", at: t0))
    }

    // MARK: Reorder

    func testMoveDownKeepsTopUnlessTopMoved() {
        var s = ClipboardStore(items: [text("d"), text("c"), text("b"), text("a")])
        XCTAssertFalse(s.move(id: "id-b", to: 1))
        XCTAssertEqual(ids(s), ["d", "b", "c", "a"])
        XCTAssertFalse(s.move(id: "id-b", to: 3))
        XCTAssertEqual(ids(s), ["d", "c", "a", "b"])
    }

    func testMoveToTopChangesCurrent() {
        var s = ClipboardStore(items: [text("c"), text("b"), text("a")])
        XCTAssertTrue(s.move(id: "id-a", to: 0))
        XCTAssertEqual(ids(s), ["a", "c", "b"])
    }

    func testMovingCurrentDownChangesCurrent() {
        var s = ClipboardStore(items: [text("c"), text("b"), text("a")])
        XCTAssertTrue(s.move(id: "id-c", to: 2))
        XCTAssertEqual(ids(s), ["b", "a", "c"])
    }

    func testMoveClampsDestination() {
        var s = ClipboardStore(items: [text("c"), text("b"), text("a")])
        s.move(id: "id-c", to: 99)
        XCTAssertEqual(ids(s), ["b", "a", "c"])
        s.move(id: "id-c", to: -5)
        XCTAssertEqual(ids(s), ["c", "b", "a"])
    }

    func testRemove() {
        var s = ClipboardStore(items: [text("c"), text("b"), text("a")])
        XCTAssertEqual(s.remove(id: "id-b")?.text, "b")
        XCTAssertEqual(ids(s), ["c", "a"])
        XCTAssertNil(s.remove(id: "id-b"))
    }

    func testClearKeepsPinned() {
        var s = ClipboardStore(items: [text("c"), text("b", pinned: true), text("a")])
        let removed = s.clearUnpinned()
        XCTAssertEqual(removed.map(\.id), ["id-c", "id-a"])
        XCTAssertEqual(ids(s), ["b"])
    }

    // MARK: Pruning

    func testPruneByCountDropsOldestFirst() {
        var s = ClipboardStore(maxCount: 3)
        for (i, name) in ["a", "b", "c"].enumerated() { _ = s.add(text(name, at: Double(i))) }
        let result = s.add(text("d", at: 10))
        XCTAssertEqual(result, .inserted(pruned: [text("a", at: 0)]))
        XCTAssertEqual(ids(s), ["d", "c", "b"])
    }

    func testPruneBySizeDropsOldestUntilUnderLimit() {
        var s = ClipboardStore(maxCount: 100, maxBytes: 100)
        _ = s.add(text("a", at: 1, bytes: 40))
        _ = s.add(text("b", at: 2, bytes: 40))
        guard case .inserted(let pruned) = s.add(text("c", at: 3, bytes: 50)) else {
            return XCTFail("expected insert")
        }
        // 130 > 100: drop "a" (oldest) → 90.
        XCTAssertEqual(pruned.map(\.id), ["id-a"])
        XCTAssertEqual(ids(s), ["c", "b"])
        XCTAssertLessThanOrEqual(s.totalBytes, 100)
    }

    func testPrunePrunesByListPositionNotTimestamp() {
        // The user dragged "old" up: list order is what counts as recency.
        var s = ClipboardStore(items: [text("new", at: 5), text("old", at: 0), text("mid", at: 3)], maxCount: 2)
        let pruned = s.prune()
        XCTAssertEqual(pruned.map(\.id), ["id-mid"])
        XCTAssertEqual(ids(s), ["new", "old"])
    }

    func testPinnedItemsAreNeverPruned() {
        var s = ClipboardStore(maxCount: 2)
        _ = s.add(text("a", at: 1, pinned: true))
        _ = s.add(text("b", at: 2, pinned: true))
        _ = s.add(text("c", at: 3))
        _ = s.add(text("d", at: 4))
        // Limit 2: "c" goes, the pinned ones stay even though that leaves 3.
        XCTAssertEqual(ids(s), ["d", "b", "a"])
        XCTAssertTrue(s.items.dropFirst().allSatisfy(\.isPinned))
    }

    func testPinnedExemptFromSizePruning() {
        var s = ClipboardStore(maxCount: 100, maxBytes: 100)
        _ = s.add(text("big", at: 1, bytes: 90, pinned: true))
        _ = s.add(text("x", at: 2, bytes: 20))
        _ = s.add(text("y", at: 3, bytes: 20))
        // 130 > 100: "x" goes (oldest unpinned); "big" stays.
        XCTAssertEqual(ids(s), ["y", "big"])
    }

    func testCurrentItemIsNeverPruned() {
        var s = ClipboardStore(maxCount: 100, maxBytes: 100)
        _ = s.add(text("a", at: 1, bytes: 10))
        let result = s.add(text("huge", at: 2, bytes: 500))
        XCTAssertEqual(result, .inserted(pruned: [text("a", at: 1, bytes: 10)]))
        XCTAssertEqual(ids(s), ["huge"], "over the limit on its own, but it's what's on the clipboard")
    }

    func testDefaultLimits() {
        XCTAssertEqual(ClipboardStore.defaultMaxCount, 1000)
        XCTAssertEqual(ClipboardStore.defaultMaxBytes, 2_147_483_648)
        var s = ClipboardStore()
        for i in 0..<1005 { _ = s.add(text("t\(i)", at: Double(i))) }
        XCTAssertEqual(s.count, 1000)
        XCTAssertEqual(s.current?.text, "t1004")
        XCTAssertEqual(s.items.last?.text, "t5")
    }

    // MARK: Filter and paging

    func testFilterMatchesTextAndFileNamesCaseInsensitively() {
        let file = ClipboardItem(id: "f", kind: .file, fingerprint: "files:/tmp/Report Final.pdf", copiedAt: t0,
                                 filePaths: ["/tmp/Report Final.pdf"], fileTypeName: "PDF document")
        let s = ClipboardStore(items: [text("Hello World"), file, text("goodbye")])
        XCTAssertEqual(s.filtered("hello").map(\.id), ["id-Hello World"])
        XCTAssertEqual(s.filtered("report").map(\.id), ["f"])
        XCTAssertEqual(s.filtered("final pdf").map(\.id), ["f"], "every word must match")
        XCTAssertEqual(s.filtered("o").count, 3)
        XCTAssertEqual(s.filtered("  ").count, 3, "blank query matches everything")
        XCTAssertEqual(s.filtered("zzz").count, 0)
    }

    func testShowMorePaging() {
        XCTAssertEqual(ClipboardStore.visibleCount(afterShowingMore: 10, total: 1000), 60)
        XCTAssertEqual(ClipboardStore.visibleCount(afterShowingMore: 60, total: 1000), 110)
        XCTAssertEqual(ClipboardStore.visibleCount(afterShowingMore: 60, total: 80), 80)
        XCTAssertEqual(ClipboardStore.visibleCount(afterShowingMore: 0, total: 1000), 60)
    }

    // MARK: Item display

    func testTitles() {
        XCTAssertEqual(text("\n  \n  first line  \nsecond").title, "first line")
        let img = ClipboardItem(kind: .image, fingerprint: "i", copiedAt: t0, pixelWidth: 1280, pixelHeight: 720)
        XCTAssertEqual(img.title, "Image 1280 × 720")
        let files = ClipboardItem(kind: .file, fingerprint: "f", copiedAt: t0, filePaths: ["/a/x.mov", "/a/y.png"])
        XCTAssertEqual(files.title, "x.mov + 1 more")
    }

    // MARK: Index encoding

    func testIndexRoundTrip() throws {
        var item = text("hello")
        item.richTextFile = "rich.rtf"
        let image = ClipboardItem(id: "img", kind: .image, fingerprint: "image:abc", copiedAt: t0,
                                  imageFile: "clip.png", thumbnailFile: "thumb.png", pixelWidth: 10, pixelHeight: 20,
                                  filePaths: ["/tmp/a.png"], storedBytes: 1234)
        let data = try ClipboardIndex(items: [item, image]).encoded()
        let back = try ClipboardIndex.decode(data)
        XCTAssertEqual(back.version, ClipboardIndex.currentVersion)
        XCTAssertEqual(back.items, [item, image])
    }

    func testIndexDecodingToleratesMissingOptionalFields() throws {
        let json = #"{"version":1,"items":[{"id":"x","kind":"text","fingerprint":"text:x","copiedAt":"2027-01-15T08:00:00Z","text":"x"}]}"#
        let index = try ClipboardIndex.decode(Data(json.utf8))
        XCTAssertEqual(index.items.first?.isPinned, false)
        XCTAssertEqual(index.items.first?.filePaths, [])
        XCTAssertEqual(index.items.first?.firstCopiedAt, index.items.first?.copiedAt)
    }
}

final class ClipboardStoreOCRTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func image(_ id: String, ocr: String?) -> ClipboardItem {
        ClipboardItem(id: id, kind: .image, fingerprint: "image:" + id, copiedAt: t0,
                      imageFile: "clip.png", pixelWidth: 10, pixelHeight: 10, ocrText: ocr)
    }

    func testSearchTextIncludesOCRText() {
        let item = image("a", ocr: "Invoice total 42 EUR")
        XCTAssertTrue(item.searchText.contains("Invoice total 42 EUR"))
        XCTAssertFalse(item.searchTextWithoutOCR.contains("Invoice"))
        XCTAssertEqual(ClipboardStore(items: [item, image("b", ocr: "")]).filtered("invoice").map(\.id), ["a"])
    }

    func testOCROnlyMatchIsDetected() {
        let snap = ClipboardItem(id: "s", kind: .file, fingerprint: "files:/p/pencil-1.png", copiedAt: t0,
                                 pixelWidth: 10, pixelHeight: 10, filePaths: ["/p/pencil-1.png"],
                                 fileTypeName: "PNG image", ocrText: "Build failed: missing module")
        XCTAssertTrue(snap.matchesOnlyInImageText("build failed"))
        XCTAssertFalse(snap.matchesOnlyInImageText("pencil"), "file name matches without OCR")
        XCTAssertTrue(snap.matches("pencil failed"), "words may come from both")
        XCTAssertTrue(snap.matchesOnlyInImageText("pencil failed"), "needs the image text for \"failed\"")
        XCTAssertFalse(image("x", ocr: nil).matchesOnlyInImageText("image"))
    }

    func testOCRCandidates() {
        XCTAssertTrue(image("a", ocr: nil).isOCRCandidate)
        let snap = ClipboardItem(kind: .file, fingerprint: "f", copiedAt: t0, pixelWidth: 5, pixelHeight: 5,
                                 filePaths: ["/a.png"])
        XCTAssertTrue(snap.isOCRCandidate)
        let video = ClipboardItem(kind: .file, fingerprint: "v", copiedAt: t0, filePaths: ["/a.mov"], isVideo: true)
        XCTAssertFalse(video.isOCRCandidate)
        XCTAssertFalse(ClipboardItem(kind: .text, fingerprint: "t", copiedAt: t0, text: "x").isOCRCandidate)
    }

    func testOldIndexWithoutOCRTextDecodes() throws {
        let json = #"{"version":1,"items":[{"id":"i","kind":"image","fingerprint":"image:1","copiedAt":"2027-01-15T08:00:00Z","imageFile":"a.png","pixelWidth":4,"pixelHeight":3,"storedBytes":10}]}"#
        let item = try XCTUnwrap(ClipboardIndex.decode(Data(json.utf8)).items.first)
        XCTAssertNil(item.ocrText, "not processed yet, so it gets backfilled")
        XCTAssertEqual(item.pixelWidth, 4)
    }

    func testOCRTextRoundTrips() throws {
        let items = [image("a", ocr: "hello"), image("b", ocr: ""), image("c", ocr: nil)]
        let back = try ClipboardIndex.decode(ClipboardIndex(items: items).encoded()).items
        XCTAssertEqual(back.map(\.ocrText), ["hello", "", nil])
    }
}
