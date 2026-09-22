import CoreGraphics
import XCTest
@testable import PencilCore

final class DockLayoutTests: XCTestCase {
    // A 900pt-tall screen with a 25pt menu bar on top and a 70pt Dock at the bottom.
    let visible = CGRect(x: 0, y: 70, width: 1440, height: 805) // 70...875
    let height: CGFloat = 380
    let offset: CGFloat = 25

    private func layout(_ anchorY: CGFloat, in v: CGRect? = nil,
                        preferring p: DockGeometry.GrowDirection = .down) -> (frame: CGRect, direction: DockGeometry.GrowDirection) {
        DockGeometry.anchoredFrame(anchorY: anchorY, handleOffset: offset, x: 0, width: 48, height: height,
                                   in: v ?? visible, preferring: p)
    }

    private func assertInside(_ r: CGRect, _ v: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThanOrEqual(r.minY, v.minY - 0.001, file: file, line: line)
        XCTAssertLessThanOrEqual(r.maxY, v.maxY + 0.001, file: file, line: line)
    }

    func testTabNearTopGrowsDownWithHandleInPlace() {
        let r = layout(840)
        XCTAssertEqual(r.direction, .down)
        XCTAssertEqual(r.frame.maxY - offset, 840, "handle center stays at the tab center")
        assertInside(r.frame, visible)
    }

    func testTabNearBottomGrowsUpWithHandleInPlace() {
        let r = layout(100)
        XCTAssertEqual(r.direction, .up)
        XCTAssertEqual(r.frame.minY + offset, 100, "handle center stays at the tab center")
        assertInside(r.frame, visible)
    }

    func testPreferredDirectionIsKeptWhenItFits() {
        XCTAssertEqual(layout(500, preferring: .up).direction, .up)
        XCTAssertEqual(layout(500, preferring: .down).direction, .down)
    }

    func testSmallScreenShiftsMinimally() {
        // 420pt visible: neither direction fits from the middle, so shift as little as possible.
        let small = CGRect(x: 0, y: 0, width: 800, height: 420)
        let r = layout(200, in: small)
        assertInside(r.frame, small)
        // Growing down from 200 would put minY at 200+25-380 = -155; growing up puts maxY
        // at 200-25+380 = 555 (135 over). Up needs the smaller shift.
        XCTAssertEqual(r.direction, .up)
        XCTAssertEqual(r.frame.maxY, 420)
    }

    func testAlwaysInsideVisibleFrame() {
        for anchor in stride(from: visible.minY, through: visible.maxY, by: 7) {
            for p in [DockGeometry.GrowDirection.down, .up] {
                assertInside(layout(anchor, preferring: p).frame, visible)
            }
        }
    }

    func testTallerThanScreenKeepsHandleEndVisible() {
        let tiny = CGRect(x: 0, y: 0, width: 800, height: 300)
        let r = layout(150, in: tiny)
        XCTAssertEqual(r.frame.maxY, tiny.maxY, "growing down, the handle end stays on screen")
    }
}
