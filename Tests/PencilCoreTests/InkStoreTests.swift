import CoreGraphics
import XCTest
@testable import PencilCore

final class InkStoreTests: XCTestCase {
    private func drawStroke(_ store: InkStore, tool: Tool, from x: CGFloat, t0: Double, count: Int = 5) {
        store.begin(tool: tool, color: .red, at: CGPoint(x: x, y: 0), time: t0)
        for i in 1..<count {
            store.extend(to: CGPoint(x: x + CGFloat(i) * 10, y: 0), time: t0 + Double(i) * 0.1)
        }
        store.end()
    }

    // MARK: Undo / clear

    func testUndoRemovesLastStroke() {
        let store = InkStore()
        drawStroke(store, tool: .pen, from: 0, t0: 0)
        drawStroke(store, tool: .highlighter, from: 100, t0: 1)
        XCTAssertEqual(store.strokes.count, 2)

        XCTAssertNotNil(store.undo())
        XCTAssertEqual(store.strokes.count, 1)
        XCTAssertEqual(store.strokes.first?.tool, .pen)

        store.undo()
        XCTAssertTrue(store.strokes.isEmpty)
        XCTAssertNil(store.undo(), "undo on empty store changes nothing")
    }

    func testUndoIgnoresLaserInk() {
        let store = InkStore()
        drawStroke(store, tool: .pen, from: 0, t0: 0)
        drawStroke(store, tool: .laser, from: 100, t0: 1)
        XCTAssertEqual(store.laserStrokes.count, 1)
        store.undo()
        XCTAssertTrue(store.strokes.isEmpty)
        XCTAssertEqual(store.laserStrokes.count, 1, "laser ink isn't part of the undo stack")
    }

    func testClearRemovesEverything() {
        let store = InkStore()
        drawStroke(store, tool: .pen, from: 0, t0: 0)
        drawStroke(store, tool: .laser, from: 100, t0: 0)
        store.begin(tool: .pen, color: .blue, at: .zero, time: 0)
        XCTAssertNotNil(store.clear())
        XCTAssertTrue(store.visibleStrokes.isEmpty)
        XCTAssertNil(store.current)
        XCTAssertNil(store.clear(), "clearing an empty store changes nothing")
    }

    func testPersistentStrokesDoNotFade() {
        let store = InkStore()
        drawStroke(store, tool: .pen, from: 0, t0: 0)
        store.pruneLaser(now: 1_000)
        XCTAssertEqual(store.strokes.first?.points.count, 5)
    }

    // MARK: Laser fade

    func testLaserFadesFromTheTail() {
        let store = InkStore(laserLifetime: 1.2)
        drawStroke(store, tool: .laser, from: 0, t0: 0) // points at t = 0, 0.1, 0.2, 0.3, 0.4

        store.pruneLaser(now: 1.0)
        XCTAssertEqual(store.laserStrokes.first?.points.count, 5, "nothing is older than 1.2s yet")

        store.pruneLaser(now: 1.25) // t=0 expired
        XCTAssertEqual(store.laserStrokes.first?.points.map(\.location.x), [10, 20, 30, 40])

        store.pruneLaser(now: 1.45) // t<=0.25 expired
        let remaining = store.laserStrokes.first?.points ?? []
        XCTAssertEqual(remaining.count, 2)
        XCTAssertEqual(remaining.first?.location.x, 30, "the oldest points go first; the head stays")

        XCTAssertTrue(store.hasFadingInk)
        store.pruneLaser(now: 2.0)
        XCTAssertTrue(store.laserStrokes.isEmpty)
        XCTAssertFalse(store.hasFadingInk, "the fade loop can stop once everything expired")
    }

    func testInProgressLaserStrokeFadesToo() {
        let store = InkStore(laserLifetime: 1.2)
        store.begin(tool: .laser, color: .red, at: .zero, time: 0)
        store.extend(to: CGPoint(x: 10, y: 0), time: 1.0)
        store.pruneLaser(now: 1.5)
        XCTAssertEqual(store.current?.points.count, 1)
        XCTAssertEqual(store.current?.points.first?.location.x, 10)
        store.pruneLaser(now: 3)
        XCTAssertEqual(store.current?.points.count, 0)
        XCTAssertFalse(store.hasFadingInk)
        // Still drawable after fully fading while the mouse is held.
        store.extend(to: CGPoint(x: 20, y: 0), time: 3.1)
        XCTAssertEqual(store.current?.points.count, 1)
        XCTAssertEqual(store.current?.pointBounds.origin.x, 20)
    }

    func testRemainingLife() {
        let store = InkStore(laserLifetime: 1.2)
        XCTAssertEqual(store.remainingLife(ofPointDrawnAt: 10, now: 10), 1)
        XCTAssertEqual(store.remainingLife(ofPointDrawnAt: 10, now: 10.6), 0.5, accuracy: 1e-9)
        XCTAssertEqual(store.remainingLife(ofPointDrawnAt: 10, now: 12), 0)
    }

    func testPruneReportsDirtyRectOnlyWhileFading() {
        let store = InkStore()
        XCTAssertNil(store.pruneLaser(now: 0))
        drawStroke(store, tool: .laser, from: 0, t0: 0)
        XCTAssertNotNil(store.pruneLaser(now: 0.5))
    }

    func testMinimumSpacingSkipsJitter() {
        let store = InkStore()
        store.begin(tool: .pen, color: .red, at: .zero, time: 0)
        XCTAssertNil(store.extend(to: CGPoint(x: 0.2, y: 0.2), time: 0.01))
        XCTAssertEqual(store.current?.points.count, 1)
    }

    // MARK: Smoothing & dock geometry

    func testSmoothSegmentsRunThroughMidpoints() {
        let pts = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 20, y: 10), CGPoint(x: 30, y: 10)]
        let segs = smoothSegments(pts)
        XCTAssertEqual(segs.count, 4)
        XCTAssertEqual(segs.first?.start, pts[0])
        XCTAssertEqual(segs.last?.end, pts[3])
        XCTAssertEqual(segs[1].control, pts[1])
        XCTAssertEqual(segs[1].start, CGPoint(x: 5, y: 0))
        XCTAssertEqual(segs[1].end, CGPoint(x: 15, y: 5))
        for (a, b) in zip(segs, segs.dropFirst()) { XCTAssertEqual(a.end, b.start, "path is continuous") }
        XCTAssertEqual(smoothSegments([.zero]).count, 1)
        XCTAssertTrue(smoothSegments([]).isEmpty)
    }

    func testDockClamp() {
        let visible = CGRect(x: 0, y: 25, width: 1000, height: 800)
        XCTAssertEqual(DockGeometry.clampY(-50, height: 44, in: visible), 25)
        XCTAssertEqual(DockGeometry.clampY(900, height: 44, in: visible), 825 - 44)
        XCTAssertEqual(DockGeometry.clampY(300, height: 44, in: visible), 300)
        XCTAssertFalse(DockGeometry.isDrag(from: .zero, to: CGPoint(x: 2, y: 3)))
        XCTAssertTrue(DockGeometry.isDrag(from: .zero, to: CGPoint(x: 0, y: 4)))
    }
}
