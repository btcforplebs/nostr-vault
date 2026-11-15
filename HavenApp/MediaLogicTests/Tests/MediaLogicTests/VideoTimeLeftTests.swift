import XCTest
@testable import MediaLogic

/// The feed clip's countdown: minutes:seconds, hours when long, nothing
/// for a live stream or a clip whose length is not known yet.
final class VideoTimeLeftTests: XCTestCase {
    func testCountsDown() {
        XCTAssertEqual(VideoTimeLeft.label(elapsed: 0, duration: 42), "0:42")
        XCTAssertEqual(VideoTimeLeft.label(elapsed: 10.4, duration: 75), "1:05")
        XCTAssertEqual(VideoTimeLeft.label(elapsed: 0, duration: 3723), "1:02:03")
    }

    /// Rounds up, so it reads 0:01 until the very end, never a stuck 0:00.
    func testRoundsUpAndStopsAtZero() {
        XCTAssertEqual(VideoTimeLeft.label(elapsed: 41.2, duration: 42), "0:01")
        XCTAssertEqual(VideoTimeLeft.label(elapsed: 50, duration: 42), "0:00")
    }

    func testNoLabelWithoutALength() {
        XCTAssertNil(VideoTimeLeft.label(elapsed: 0, duration: .nan))
        XCTAssertNil(VideoTimeLeft.label(elapsed: 0, duration: .infinity))
        XCTAssertNil(VideoTimeLeft.label(elapsed: 0, duration: 0))
        XCTAssertNil(VideoTimeLeft.label(elapsed: .nan, duration: 30))
    }
}
