import CoreGraphics
import XCTest
@testable import PencilCore

final class EditPillTests: XCTestCase {
    // Visible frame 70...875 (Dock at the bottom, menu bar on top).
    let visible = CGRect(x: 0, y: 70, width: 1440, height: 805)
    let size = CGSize(width: 36, height: 64)

    private func tile(centerY: CGFloat) -> CGRect { CGRect(x: 0, y: centerY - 16, width: 36, height: 32) }

    private func pill(_ anchor: CGRect, preferBelow: Bool = true) -> CGRect {
        DockGeometry.editPillFrame(anchor: anchor, x: 0, size: size, preferBelow: preferBelow, in: visible)
    }

    func testCollapsedMiddleGoesBelowTheTile() {
        let t = tile(centerY: 500)
        let p = pill(t)
        XCTAssertEqual(p.maxY, t.minY - 6)
        XCTAssertEqual(p.minX, 0, "flush with the screen edge")
    }

    func testCollapsedTopGoesBelow() {
        let t = tile(centerY: 850)
        XCTAssertEqual(pill(t).maxY, t.minY - 6)
    }

    func testCollapsedNearBottomFallsBackAbove() {
        let t = tile(centerY: 100) // 84...116: no room for 64 + 6 below
        let p = pill(t)
        XCTAssertEqual(p.minY, t.maxY + 6)
        XCTAssertTrue(visible.contains(p))
    }

    func testExpandedGrowingDownGoesPastTheFarEnd() {
        let toolbar = CGRect(x: 0, y: 400, width: 48, height: 380) // handle at the top
        let p = pill(toolbar, preferBelow: true)
        XCTAssertEqual(p.maxY, toolbar.minY - 6)
    }

    func testExpandedGrowingUpGoesPastTheTop() {
        let toolbar = CGRect(x: 0, y: 90, width: 48, height: 380) // handle at the bottom
        let p = pill(toolbar, preferBelow: false)
        XCTAssertEqual(p.minY, toolbar.maxY + 6)
    }

    func testExpandedNoRoomAtFarEndUsesHandleSide() {
        // Grows down to near the bottom: no room below, so above the handle end.
        let toolbar = CGRect(x: 0, y: 80, width: 48, height: 380)
        let p = pill(toolbar, preferBelow: true)
        XCTAssertEqual(p.minY, toolbar.maxY + 6)
        // Grows up to near the top: no room above, so below the handle end.
        let up = CGRect(x: 0, y: 480, width: 48, height: 390)
        XCTAssertEqual(pill(up, preferBelow: false).maxY, up.minY - 6)
    }

    func testNoRoomAnywhereIsClamped() {
        let tall = CGRect(x: 0, y: 72, width: 48, height: 800)
        let p = pill(tall)
        XCTAssertTrue(visible.contains(p))
    }
}
