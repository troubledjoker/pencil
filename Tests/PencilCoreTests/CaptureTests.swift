import CoreGraphics
import XCTest
@testable import PencilCore

final class CaptureTests: XCTestCase {
    func testFileNameFormat() {
        let utc = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: 1_790_000_000) // 2026-09-21 14:13:20 UTC
        XCTAssertEqual(CapturePlan.fileName(for: date, timeZone: utc), "pencil-20260921-141320.png")
        XCTAssertEqual(CapturePlan.fileName(for: date, attempt: 3, timeZone: utc), "pencil-20260921-141320-3.png")
    }

    func testCaptureRectPerKind() {
        let screen = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        XCTAssertEqual(CapturePlan.captureRect(for: .screenUnderMouse, screenFrame: screen), screen)
        XCTAssertNil(CapturePlan.captureRect(for: .region, screenFrame: screen), "region needs the picker")
        XCTAssertEqual(CapturePlan.captureRect(for: .area(CGRect(x: 1400, y: 100, width: 200, height: 50)), screenFrame: screen),
                       CGRect(x: 1440, y: 100, width: 160, height: 50), "clamped to the screen")
        XCTAssertNil(CapturePlan.captureRect(for: .area(CGRect(x: 0, y: 0, width: 10, height: 10)), screenFrame: screen))
    }

    func testFullScreenSourceRectIsTheWholeDisplay() {
        let screen = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        XCTAssertEqual(RecordingPlan.sourceRect(selection: screen, screenFrame: screen),
                       CGRect(x: 0, y: 0, width: 1920, height: 1080))
        // A screen above the primary one (negative-free global y) still maps to its own top-left.
        let above = CGRect(x: 0, y: 900, width: 1440, height: 900)
        XCTAssertEqual(RecordingPlan.sourceRect(selection: CGRect(x: 100, y: 1700, width: 200, height: 100), screenFrame: above),
                       CGRect(x: 100, y: 0, width: 200, height: 100))
    }

    func testStillPixelSize() {
        let px = CapturePlan.stillPixelSize(for: CGRect(x: 0, y: 0, width: 401, height: 299), scale: 2)
        XCTAssertEqual(px.width, 802)
        XCTAssertEqual(px.height, 598)
        XCTAssertEqual(CapturePlan.stillPixelSize(for: CGRect(x: 0, y: 0, width: 333, height: 111), scale: 1).width, 333,
                       "stills don't need even sizes")
    }
}
