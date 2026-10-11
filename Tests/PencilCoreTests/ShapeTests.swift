import CoreGraphics
import XCTest
@testable import PencilCore

final class ShapeTests: XCTestCase {
    private func drag(_ store: InkStore, _ tool: Tool, from a: CGPoint, to b: CGPoint, constrain: Bool = false) {
        store.begin(tool: tool, color: .red, at: a, time: 0)
        store.extend(to: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), time: 0.1, constrain: constrain)
        store.extend(to: b, time: 0.2, constrain: constrain)
        store.end()
    }

    func testRectangleIsItsFourCornersClosed() {
        let store = InkStore()
        drag(store, .rectangle, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 110, y: 60))
        XCTAssertEqual(store.strokes.count, 1)
        XCTAssertEqual(store.strokes[0].points.map(\.location),
                       [CGPoint(x: 10, y: 10), CGPoint(x: 110, y: 10), CGPoint(x: 110, y: 60),
                        CGPoint(x: 10, y: 60), CGPoint(x: 10, y: 10)],
                       "redrawn from the anchor, not appended to")
    }

    func testLineIsTwoPoints() {
        let store = InkStore()
        drag(store, .line, from: .zero, to: CGPoint(x: 50, y: 20))
        XCTAssertEqual(store.strokes[0].points.map(\.location), [.zero, CGPoint(x: 50, y: 20)])
    }

    func testShiftMakesSquaresCirclesAnd45Degrees() {
        XCTAssertEqual(ShapeGeometry.constrainedEnd(.rectangle, from: .zero, to: CGPoint(x: 100, y: -40)),
                       CGPoint(x: 100, y: -100))
        let end = ShapeGeometry.constrainedEnd(.line, from: .zero, to: CGPoint(x: 100, y: 10))
        XCTAssertEqual(end.x, 100.4987, accuracy: 0.001)
        XCTAssertEqual(end.y, 0, accuracy: 0.0001, "snaps to horizontal")
        let circle = ShapeGeometry.points(.ellipse, from: .zero, to: CGPoint(x: 80, y: 30), constrain: true, lineWidth: 4)
        let xs = circle.map(\.x), ys = circle.map(\.y)
        XCTAssertEqual(xs.max()! - xs.min()!, ys.max()! - ys.min()!, accuracy: 0.01)
    }

    func testEllipseIsClosed() {
        let pts = ShapeGeometry.points(.ellipse, from: .zero, to: CGPoint(x: 100, y: 50), constrain: false, lineWidth: 4)
        XCTAssertEqual(pts.first!.x, pts.last!.x, accuracy: 0.0001)
        XCTAssertEqual(pts.first!.y, pts.last!.y, accuracy: 0.0001)
    }

    func testArrowHasATipAndTwoWings() {
        let pts = ShapeGeometry.points(.arrow, from: .zero, to: CGPoint(x: 100, y: 0), constrain: false, lineWidth: 4)
        XCTAssertEqual(pts.count, 5)
        XCTAssertEqual(pts[1], CGPoint(x: 100, y: 0))
        XCTAssertEqual(pts[3], CGPoint(x: 100, y: 0))
        XCTAssertLessThan(pts[2].x, 100)
        XCTAssertEqual(pts[2].y, -pts[4].y, accuracy: 0.0001, "wings are symmetric")
    }

    func testAClickWithAShapeToolLeavesNothing() {
        let store = InkStore()
        drag(store, .rectangle, from: CGPoint(x: 5, y: 5), to: CGPoint(x: 6, y: 6))
        XCTAssertTrue(store.strokes.isEmpty)
        XCTAssertFalse(store.canUndo)
    }

    func testShapesUndoLikeInk() {
        let store = InkStore()
        drag(store, .ellipse, from: .zero, to: CGPoint(x: 40, y: 40))
        XCTAssertTrue(store.hasPersistentInk)
        store.undo()
        XCTAssertFalse(store.hasPersistentInk)
    }

    func testShiftChangeWithoutMovingReshapes() {
        let store = InkStore()
        store.begin(tool: .rectangle, color: .red, at: .zero, time: 0)
        store.extend(to: CGPoint(x: 100, y: 40), time: 0.1)
        XCTAssertNotNil(store.reshapeCurrent(constrain: true, time: 0.2))
        XCTAssertEqual(store.current?.points[2].location, CGPoint(x: 100, y: 100))
    }
}
