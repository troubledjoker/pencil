import XCTest
@testable import PencilCore

final class ClipboardStoreDiskTests: XCTestCase {
    private var root: URL!
    private var disk: ClipboardStoreDisk!
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pencil-clipboard-tests-\(UUID().uuidString)", isDirectory: true)
        disk = ClipboardStoreDisk(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testDefaultRootIsUnderApplicationSupport() {
        XCTAssertTrue(ClipboardStoreDisk.defaultRoot.path.hasSuffix("Library/Application Support/Pencil/Clipboard"))
    }

    func testMissingIndexLoadsEmpty() {
        XCTAssertEqual(disk.loadItems(), [])
    }

    func testSaveAndLoadSurvivesRelaunch() throws {
        let text = ClipboardItem(id: "t", kind: .text, fingerprint: "text:1", copiedAt: t0, isPinned: true, text: "hi")
        let size = try disk.writeBlob(Data(repeating: 7, count: 100), named: "clip.png", for: "i")
        XCTAssertEqual(size, 100)
        let image = ClipboardItem(id: "i", kind: .image, fingerprint: "image:1", copiedAt: t0,
                                  imageFile: "clip.png", storedBytes: size)
        try disk.save([text, image])
        let loaded = ClipboardStoreDisk(root: root).loadItems()
        XCTAssertEqual(loaded, [text, image])
        XCTAssertEqual(disk.folderSize(for: "i"), 100)
    }

    func testImageWithMissingBlobIsDroppedOnLoad() throws {
        let image = ClipboardItem(id: "gone", kind: .image, fingerprint: "image:2", copiedAt: t0, imageFile: "clip.png")
        let text = ClipboardItem(id: "t", kind: .text, fingerprint: "text:1", copiedAt: t0, text: "hi")
        try disk.save([image, text])
        XCTAssertEqual(disk.loadItems().map(\.id), ["t"])
    }

    func testCorruptIndexIsMovedAside() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: disk.indexURL)
        XCTAssertEqual(disk.loadItems(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: disk.indexURL.path))
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("index.corrupt-") })
    }

    func testRemoveFolderAndOrphans() throws {
        try disk.writeBlob(Data([1]), named: "a", for: "keep")
        try disk.writeBlob(Data([1]), named: "a", for: "orphan")
        try disk.writeBlob(Data([1]), named: "a", for: "delete-me")
        disk.removeFolder(for: "delete-me")
        XCTAssertFalse(FileManager.default.fileExists(atPath: disk.folder(for: "delete-me").path))
        XCTAssertEqual(disk.removeOrphans(keeping: ["keep"]), ["orphan"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: disk.folder(for: "keep").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: disk.folder(for: "orphan").path))
    }

    func testBlobURL() {
        XCTAssertNil(disk.blobURL(nil, of: "x"))
        XCTAssertEqual(disk.blobURL("t.png", of: "x")?.lastPathComponent, "t.png")
        XCTAssertEqual(disk.blobURL("t.png", of: "x")?.deletingLastPathComponent().lastPathComponent, "x")
    }
}
