import XCTest
@testable import PencilCore

final class ClipboardBatchTests: XCTestCase {
    private func item(_ id: String, batch: String? = nil, at t: TimeInterval) -> ClipboardItem {
        ClipboardItem(id: id, kind: .file, fingerprint: "files:\(id)", copiedAt: Date(timeIntervalSince1970: t),
                      filePaths: ["/tmp/\(id).png"], batchID: batch)
    }

    func testGroupingBatchItems() {
        let items = [item("c", batch: "B", at: 3), item("b", batch: "B", at: 2), item("a", batch: "B", at: 1),
                     item("x", at: 0), item("y", batch: "C", at: -1)]
        let entries = ClipboardGrouping.entries(items)
        XCTAssertEqual(entries.count, 3)
        guard case .group(let g) = entries[0] else { return XCTFail("expected a folder") }
        XCTAssertEqual(g.kind, .burst(batchID: "B"))
        XCTAssertEqual(g.items.map(\.id), ["c", "b", "a"])
        XCTAssertEqual(entries[1], .single(items[3]))
        XCTAssertEqual(entries[2], .single(items[4]), "a lone batch item is a plain row")
        XCTAssertEqual(entries[0].key, "burst:B")
    }

    func testSplitBatchIsStillOneFolderAtItsNewestMember() {
        let items = [item("b2", batch: "B", at: 5), item("b1", batch: "B", at: 4), item("x", at: 3),
                     item("b0", batch: "B", at: 2), item("bz", batch: "B", at: 1)]
        let entries = ClipboardGrouping.entries(items)
        XCTAssertEqual(entries.map(\.key), ["burst:B", "x"])
        XCTAssertEqual(entries[0].items.map(\.id), ["b2", "b1", "b0", "bz"])
    }

    func testBatchWriteBackOrderIsCaptureOrder() {
        var store = ClipboardStore(items: [item("c", batch: "B", at: 3), item("x", at: 2.5),
                                           item("b", batch: "B", at: 2), item("a", batch: "B", at: 1)])
        XCTAssertEqual(store.batchItems("B").map(\.id), ["a", "b", "c"], "oldest first on the pasteboard")
        XCTAssertTrue(store.promoteBatch("B", at: Date(timeIntervalSince1970: 10)))
        XCTAssertEqual(store.items.map(\.id), ["c", "b", "a", "x"], "batch moves up together, newest first")
        XCTAssertTrue(store.items.prefix(3).allSatisfy { $0.copiedAt == Date(timeIntervalSince1970: 10) })
        XCTAssertFalse(store.promoteBatch("nope", at: Date()))
    }

    func testBatchIDIsBackwardCompatibleJSON() throws {
        let old = #"{"version":1,"items":[{"id":"1","kind":"text","fingerprint":"t","copiedAt":"2026-09-22T10:00:00Z","text":"hi"}]}"#
        let index = try ClipboardIndex.decode(Data(old.utf8))
        XCTAssertNil(index.items[0].batchID)
        let roundTrip = try ClipboardIndex.decode(ClipboardIndex(items: [item("a", batch: "B", at: 1)]).encoded())
        XCTAssertEqual(roundTrip.items[0].batchID, "B")
    }

    func testSetBatch() {
        var store = ClipboardStore(items: [item("a", at: 1)])
        store.setBatch(id: "a", "B")
        XCTAssertEqual(store.items[0].batchID, "B")
    }
}
