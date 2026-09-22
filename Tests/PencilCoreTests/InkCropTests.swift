import CoreGraphics
import XCTest
@testable import PencilCore

final class InkCropTests: XCTestCase {
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    func testSingleStrokeIsPadded() {
        let r = CapturePlan.inkCropRect(inkBounds: [CGRect(x: 500, y: 400, width: 100, height: 50)], screenFrame: screen)
        XCTAssertEqual(r, CGRect(x: 380, y: 280, width: 340, height: 290))
    }

    func testSpreadStrokesUnion() {
        let r = CapturePlan.inkCropRect(inkBounds: [
            CGRect(x: 300, y: 300, width: 10, height: 10),
            CGRect(x: 900, y: 600, width: 20, height: 20),
        ], screenFrame: screen)
        XCTAssertEqual(r, CGRect(x: 180, y: 180, width: 860, height: 560))
    }

    func testNearEdgeIsClamped() {
        let r = CapturePlan.inkCropRect(inkBounds: [CGRect(x: 20, y: 850, width: 60, height: 40)], screenFrame: screen)
        XCTAssertEqual(r, CGRect(x: 0, y: 730, width: 200, height: 170))
        XCTAssertTrue(screen.contains(r!))
    }

    func testEmptyOrOtherScreenIsNil() {
        XCTAssertNil(CapturePlan.inkCropRect(inkBounds: [], screenFrame: screen))
        XCTAssertNil(CapturePlan.inkCropRect(inkBounds: [CGRect(x: 2000, y: 100, width: 50, height: 50)],
                                             screenFrame: screen), "ink on another screen doesn't count")
    }

    func testSecondaryScreenCoordinates() {
        let second = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let r = CapturePlan.inkCropRect(inkBounds: [CGRect(x: 1500, y: 500, width: 100, height: 100),
                                                    CGRect(x: 200, y: 200, width: 10, height: 10)],
                                        screenFrame: second)
        XCTAssertEqual(r, CGRect(x: 1440, y: 380, width: 280, height: 340))
    }

    // MARK: Recording geometry

    func testRecordingSourceRectIsDisplayLocalTopLeft() {
        let second = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let src = RecordingPlan.sourceRect(selection: CGRect(x: 1540, y: 80, width: 400, height: 300), screenFrame: second)
        XCTAssertEqual(src, CGRect(x: 100, y: 700, width: 400, height: 300))
    }

    func testPixelSizeIsEven() {
        let px = RecordingPlan.pixelSize(for: CGRect(x: 0, y: 0, width: 401.4, height: 299), scale: 2)
        XCTAssertEqual(px.width, 802)
        XCTAssertEqual(px.height, 598)
        XCTAssertEqual(RecordingPlan.pixelSize(for: CGRect(x: 0, y: 0, width: 333, height: 111), scale: 1).width, 332)
    }

    func testElapsedLabelAndSelection() {
        XCTAssertEqual(RecordingPlan.elapsedLabel(12.7), "0:12")
        XCTAssertEqual(RecordingPlan.elapsedLabel(245), "4:05")
        XCTAssertEqual(RecordingPlan.selection(from: CGPoint(x: 300, y: 100), to: CGPoint(x: 100, y: 400), in: screen),
                       CGRect(x: 100, y: 100, width: 200, height: 300))
        XCTAssertEqual(RecordingPlan.selection(from: CGPoint(x: 1400, y: 10), to: CGPoint(x: 1600, y: -50), in: screen),
                       CGRect(x: 1400, y: 0, width: 40, height: 10), "clamped to the screen")
        XCTAssertEqual(RecordingPlan.maxDuration, 300)
    }

    func testRecordingFileName() {
        let utc = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertEqual(CapturePlan.fileName(for: date, timeZone: utc, prefix: "pencil-rec", ext: "mp4"),
                       "pencil-rec-20260921-141320.mp4")
    }
}
