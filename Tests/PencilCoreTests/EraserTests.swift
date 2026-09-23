import CoreGraphics
import XCTest
@testable import PencilCore

final class EraserTests: XCTestCase {
    /// A horizontal pen stroke from x0 to x1 at y, one point every `spacing`.
    private func line(_ store: InkStore, y: CGFloat = 0, from x0: CGFloat = 0, to x1: CGFloat = 100,
                      spacing: CGFloat = 10, width: CGFloat = 4) {
        store.begin(tool: .pen, color: .red, width: width, at: CGPoint(x: x0, y: y), time: 0)
        var x = x0 + spacing
        while x <= x1 {
            store.extend(to: CGPoint(x: x, y: y), time: Double(x))
            x += spacing
        }
        store.end()
    }

    private func erase(_ store: InkStore, _ tool: Tool, radius: CGFloat = 5, _ path: CGPoint...) {
        store.beginErase(tool: tool, radius: radius, at: path[0])
        for p in path.dropFirst() { store.extendErase(to: p) }
        store.endErase()
    }

    func testErasersAreTools() {
        XCTAssertTrue(Tool.eraser.isEraser)
        XCTAssertTrue(Tool.objectEraser.isEraser)
        XCTAssertFalse(Tool.pen.isEraser)
        XCTAssertEqual(Mode.draw(.eraser).displayName, "Eraser")
        XCTAssertGreaterThan(Tool.eraser.lineWidth(level: 7), Tool.eraser.lineWidth(level: 1), "size applies")
    }

    func testEraserCutsAStrokeInTwo() {
        let store = InkStore()
        line(store)
        erase(store, .eraser, CGPoint(x: 50, y: 20), CGPoint(x: 50, y: -20))
        XCTAssertEqual(store.strokes.count, 2)
        let xs = store.strokes.map { $0.points.map(\.location.x) }
        XCTAssertTrue(xs[0].allSatisfy { $0 < 43 }, "left piece stops short of the eraser")
        XCTAssertTrue(xs[1].allSatisfy { $0 > 57 }, "right piece starts past the eraser")
        XCTAssertEqual(xs[0].first, 0)
        XCTAssertEqual(xs[1].last, 100)
    }

    func testEraserCutsBetweenSparsePoints() {
        // Points 100pt apart: the eraser passes between them and must still cut the line.
        let store = InkStore()
        line(store, spacing: 100)
        erase(store, .eraser, CGPoint(x: 50, y: 20), CGPoint(x: 50, y: -20))
        XCTAssertEqual(store.strokes.count, 2)
    }

    func testEraserMissLeavesInkAlone() {
        let store = InkStore()
        line(store)
        let before = store.strokes.map(\.id)
        XCTAssertNil(store.beginErase(tool: .eraser, radius: 5, at: CGPoint(x: 50, y: 40)))
        store.endErase()
        XCTAssertEqual(store.strokes.map(\.id), before)
        store.undo()
        XCTAssertTrue(store.strokes.isEmpty, "a miss isn't an undo step: undo removes the stroke")
    }

    func testErasingAWholeStrokeRemovesIt() {
        let store = InkStore()
        line(store, from: 0, to: 20)
        erase(store, .eraser, radius: 30, CGPoint(x: 10, y: 0))
        XCTAssertTrue(store.strokes.isEmpty)
        XCTAssertFalse(store.hasPersistentInk)
    }

    func testObjectEraserRemovesOnlyTouchedStrokes() {
        let store = InkStore()
        line(store, y: 0)
        line(store, y: 100)
        let kept = store.strokes[1].id
        erase(store, .objectEraser, CGPoint(x: 30, y: 20), CGPoint(x: 30, y: -20))
        XCTAssertEqual(store.strokes.map(\.id), [kept])
    }

    func testObjectEraserCatchesAFastSweepAcrossALine() {
        // The eraser jumps from above to below the stroke in one move.
        let store = InkStore()
        line(store, spacing: 100)
        erase(store, .objectEraser, radius: 1, CGPoint(x: 50, y: 300), CGPoint(x: 50, y: -300))
        XCTAssertTrue(store.strokes.isEmpty)
    }

    func testOneGestureIsOneUndoStep() {
        let store = InkStore()
        line(store, y: 0)
        line(store, y: 100)
        erase(store, .objectEraser, CGPoint(x: 30, y: 0), CGPoint(x: 30, y: 100))
        XCTAssertTrue(store.strokes.isEmpty)
        XCTAssertNotNil(store.undo())
        XCTAssertEqual(store.strokes.count, 2, "both strokes come back together")
        store.undo()
        XCTAssertEqual(store.strokes.count, 1, "then undo goes on removing drawn strokes")
    }

    func testUndoRestoresACutStroke() {
        let store = InkStore()
        line(store)
        let original = store.strokes[0]
        erase(store, .eraser, CGPoint(x: 50, y: 20), CGPoint(x: 50, y: -20))
        let dirty = store.undo()
        XCTAssertEqual(store.strokes.map(\.id), [original.id])
        XCTAssertEqual(store.strokes[0].points, original.points)
        XCTAssertTrue(dirty?.contains(original.renderBounds) == true, "redraws the whole restored stroke")
    }

    func testStrokeWidthExtendsTheEraserReach() {
        // A 20pt-wide stroke at y=0 is touched by an eraser at y=14 with radius 5 (5 + 10 ≥ 14).
        let store = InkStore()
        line(store, width: 20)
        erase(store, .objectEraser, CGPoint(x: 50, y: 14))
        XCTAssertTrue(store.strokes.isEmpty)
    }

    func testUndoBringsBackClearedInk() {
        let store = InkStore()
        line(store, y: 0)
        line(store, y: 100)
        store.clear()
        XCTAssertFalse(store.hasPersistentInk)
        XCTAssertNotNil(store.undo())
        XCTAssertEqual(store.strokes.count, 2, "clear is one undo step")
        store.clear()
        store.clear()
        store.undo()
        XCTAssertEqual(store.strokes.count, 2, "clearing nothing adds no undo step")
    }
}
