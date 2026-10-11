import XCTest
@testable import PencilCore

final class ClipboardSelectionTests: XCTestCase {
    private func item(_ id: String, _ kind: ClipboardItem.Kind = .file, batch: String? = nil, at t: TimeInterval,
                      video: Bool = false, width: Int? = nil) -> ClipboardItem {
        ClipboardItem(id: id, kind: kind, fingerprint: "\(kind):\(id)", copiedAt: Date(timeIntervalSince1970: t),
                      pixelWidth: width, filePaths: kind == .file ? ["/tmp/\(id)"] : [], isVideo: video, batchID: batch)
    }

    func testToggleKeepsPickOrder() {
        var s = ClipboardSelection()
        s.toggle("b"); s.toggle("a"); s.toggle("c")
        XCTAssertEqual(s.ids, ["b", "a", "c"])
        s.toggle("a")
        XCTAssertEqual(s.ids, ["b", "c"])
        XCTAssertTrue(s.contains("c"))
        XCTAssertFalse(s.contains("a"))
        XCTAssertEqual(ClipboardSelection(["x", "x", "y"]).ids, ["x", "y"])
    }

    func testFolderStateAndToggleAll() {
        var s = ClipboardSelection(["a"])
        XCTAssertEqual(s.state(of: ["a", "b"]), .some)
        XCTAssertEqual(s.state(of: ["c"]), .none)
        s.toggleAll(["a", "b"])
        XCTAssertEqual(s.state(of: ["a", "b"]), .all, "a partly picked folder becomes fully picked")
        XCTAssertEqual(s.ids, ["a", "b"])
        s.toggleAll(["a", "b"])
        XCTAssertTrue(s.isEmpty, "a fully picked folder becomes unpicked")
    }

    func testKeepDropsDeletedItems() {
        var s = ClipboardSelection(["a", "b", "c"])
        s.keep(only: ["a", "c", "z"])
        XCTAssertEqual(s.ids, ["a", "c"])
    }

    func testGroupTagsPickedItemsAsOneFolder() {
        var store = ClipboardStore(items: [item("c", at: 3), item("x", at: 2.5), item("b", batch: "OLD", at: 2),
                                           item("a", .text, at: 1)])
        XCTAssertEqual(store.group(["a", "c", "gone", "b"], as: "G"), 3)
        XCTAssertEqual(store.batchItems("G").map(\.id), ["a", "b", "c"], "paste order is oldest first")
        XCTAssertTrue(store.batchItems("OLD").isEmpty, "an item moves out of its old burst")
        XCTAssertTrue(store.promoteBatch("G", at: Date(timeIntervalSince1970: 10)))
        let entries = ClipboardGrouping.entries(store.items)
        XCTAssertEqual(entries.map(\.key), ["burst:G", "x"])
        XCTAssertEqual(store.current?.batchID, "G")
    }

    func testJoinedText() {
        XCTAssertEqual(ClipboardJoin.text(["  one ", "", "two\n", "  "]), "one\n\ntwo")
        XCTAssertEqual(ClipboardJoin.text([]), "")
    }

    func testGroupSummary() {
        let items = [item("i1", .image, at: 1), item("f1", at: 2, width: 800), item("v1", at: 3, video: true),
                     item("v2", at: 4, video: true), item("d", at: 5), item("t", .text, at: 6)]
        XCTAssertEqual(ClipboardFormat.groupSummary(items), "2 images, 2 videos, 1 file, 1 text")
        XCTAssertEqual(ClipboardFormat.groupSummary([item("i", .image, at: 1)]), "1 image")
    }
}
