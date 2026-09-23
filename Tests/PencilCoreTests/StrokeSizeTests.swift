import CoreGraphics
import XCTest
@testable import PencilCore

final class StrokeSizeTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        suite = "pencil.tests.size.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testDefaultIsLevelThreeWithTodaysWidths() {
        let s = StrokeSizeSetting(defaults: defaults)
        XCTAssertEqual(s.level, 3)
        XCTAssertEqual(s.width(for: .pen), 4)
        XCTAssertEqual(s.width(for: .highlighter), 18)
        XCTAssertEqual(s.width(for: .laser), 3)
    }

    func testClampsAtOneAndSeven() {
        let s = StrokeSizeSetting(defaults: defaults)
        XCTAssertTrue(s.set(99))
        XCTAssertEqual(s.level, 7)
        XCTAssertFalse(s.step(by: 1), "already at the top")
        XCTAssertEqual(s.level, 7)
        s.set(-4)
        XCTAssertEqual(s.level, 1)
        XCTAssertFalse(s.step(by: -1), "already at the bottom")
        XCTAssertEqual(s.level, 1)
        XCTAssertEqual(StrokeSize.clamp(0), 1)
        XCTAssertEqual(StrokeSize.clamp(8), 7)
        defaults.set(42, forKey: StrokeSizeSetting.defaultsKey)
        XCTAssertEqual(StrokeSizeSetting(defaults: defaults).level, 7, "a bad stored value is clamped")
    }

    func testMultiplierPerTool() {
        let expected: [CGFloat] = [0.5, 0.7, 1.0, 1.4, 1.9, 2.6, 3.4]
        for (i, m) in expected.enumerated() {
            let level = i + 1
            XCTAssertEqual(StrokeSize.multiplier(level), m)
            for tool in Tool.allCases {
                XCTAssertEqual(tool.lineWidth(level: level), tool.baseLineWidth * m, accuracy: 0.0001)
            }
            // The highlighter stays proportionally thicker than the pen at every level.
            XCTAssertEqual(Tool.highlighter.lineWidth(level: level) / Tool.pen.lineWidth(level: level),
                           18.0 / 4.0, accuracy: 0.0001)
        }
        XCTAssertEqual(Tool.pen.lineWidth(level: 7), 13.6, accuracy: 0.0001)
        XCTAssertEqual(Tool.highlighter.lineWidth(level: 1), 9, accuracy: 0.0001)
    }

    func testLevelIsSharedAcrossToolSwitchesAndPersisted() {
        let s = StrokeSizeSetting(defaults: defaults)
        s.step(by: 2) // 5 while using the pen
        var mode = Mode.draw(.pen)
        XCTAssertEqual(s.width(for: mode.tool!), 4 * 1.9, accuracy: 0.0001)
        mode = Shortcuts.toggled(mode, tool: .highlighter)
        XCTAssertEqual(s.level, 5, "switching tools keeps the size")
        XCTAssertEqual(s.width(for: mode.tool!), 18 * 1.9, accuracy: 0.0001)
        XCTAssertEqual(StrokeSizeSetting(defaults: defaults).level, 5, "persisted across launches")
    }

    func testExistingStrokesKeepTheirWidth() {
        let s = StrokeSizeSetting(defaults: defaults)
        let store = InkStore()
        store.begin(tool: .pen, color: .red, width: s.width(for: .pen), at: .zero, time: 0)
        store.extend(to: CGPoint(x: 50, y: 0), time: 0.1)
        store.end()
        let before = store.strokes[0].renderBounds
        s.set(7)
        store.begin(tool: .pen, color: .red, width: s.width(for: .pen), at: CGPoint(x: 0, y: 100), time: 1)
        store.extend(to: CGPoint(x: 50, y: 100), time: 1.1)
        store.end()
        XCTAssertEqual(store.strokes[0].lineWidth, 4, "the old stroke is unchanged")
        XCTAssertEqual(store.strokes[0].renderBounds, before)
        XCTAssertEqual(store.strokes[1].lineWidth, 13.6, accuracy: 0.0001)
        XCTAssertGreaterThan(store.strokes[1].renderPadding, store.strokes[0].renderPadding)
    }

    func testDefaultWidthIsTheToolsBase() {
        let store = InkStore()
        store.begin(tool: .highlighter, color: .red, at: .zero, time: 0)
        XCTAssertEqual(store.current?.lineWidth, 18)
    }
}
