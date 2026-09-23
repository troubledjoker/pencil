import CoreGraphics
import XCTest
@testable import PencilCore

final class SizeTrackTests: XCTestCase {
    // 7 levels over 120pt: one level every 20pt.
    let track = SizeTrack(minX: 10, maxX: 130)

    func testEndsMapToTheSmallestAndLargestLevel() {
        XCTAssertEqual(track.x(for: 1), 10)
        XCTAssertEqual(track.x(for: 7), 130)
        XCTAssertEqual(track.level(at: 10), 1)
        XCTAssertEqual(track.level(at: 130), 7)
    }

    func testMidpointIsTheMiddleLevel() {
        XCTAssertEqual(track.x(for: 4), 70)
        XCTAssertEqual(track.level(at: 70), 4)
        XCTAssertEqual(track.fraction(at: 70), 0.5)
    }

    func testEveryLevelRoundTrips() {
        XCTAssertEqual(track.step, 20)
        for level in StrokeSize.levels {
            XCTAssertEqual(track.level(at: track.x(for: level)), level)
        }
    }

    func testSnapsToTheNearestLevel() {
        XCTAssertEqual(track.level(at: 38), 2, "past level 2's tick (30), under halfway to 3")
        XCTAssertEqual(track.level(at: 22), 2)
        XCTAssertEqual(track.level(at: 19), 1, "under halfway to level 2")
        XCTAssertEqual(track.level(at: 41), 3, "over halfway from 2 to 3")
        XCTAssertEqual(track.level(at: 121), 7)
        XCTAssertEqual(track.level(at: 119), 6)
    }

    func testClampsBeyondTheTrack() {
        XCTAssertEqual(track.level(at: -500), 1)
        XCTAssertEqual(track.level(at: 9_999), 7)
        XCTAssertEqual(track.fraction(at: -5), 0)
        XCTAssertEqual(track.fraction(at: 500), 1)
        XCTAssertEqual(track.x(for: 0), 10, "a level below 1 is clamped")
        XCTAssertEqual(track.x(for: 12), 130, "a level above 7 is clamped")
    }

    func testWedgeGrowsFromThinToThick() {
        XCTAssertEqual(track.wedgeThickness(at: 10, thin: 2, thick: 14), 2)
        XCTAssertEqual(track.wedgeThickness(at: 70, thin: 2, thick: 14), 8)
        XCTAssertEqual(track.wedgeThickness(at: 130, thin: 2, thick: 14), 14)
        XCTAssertEqual(track.wedgeThickness(at: 400, thin: 2, thick: 14), 14, "clamped past the end")
    }

    func testDegenerateTrackStaysAtLevelOne() {
        let flat = SizeTrack(minX: 50, maxX: 50)
        XCTAssertEqual(flat.level(at: 80), 1)
        XCTAssertEqual(flat.x(for: 7), 50)
    }
}
