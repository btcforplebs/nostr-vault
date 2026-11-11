import XCTest
import CoreGraphics
@testable import MediaLogic

/// Full-screen viewers share one landscape slot count: the phone goes
/// upright only when the last one closes.
final class LandscapeCountTests: XCTestCase {
    func testOpenOpenCloseStaysAllowedThenLastCloseTurnsUpright() {
        var count = LandscapeCount()
        XCTAssertFalse(count.allowsLandscape)
        count.opened()
        count.opened()
        XCTAssertFalse(count.closed(), "one viewer still open")
        XCTAssertTrue(count.allowsLandscape)
        XCTAssertTrue(count.closed(), "last close asks for upright")
        XCTAssertFalse(count.allowsLandscape)
    }

    func testExtraCloseDoesNothing() {
        var count = LandscapeCount()
        XCTAssertFalse(count.closed())
        XCTAssertEqual(count.open, 0)
        count.opened()
        XCTAssertTrue(count.allowsLandscape)
    }

    func testOnlyWideClipsTurnSideways() {
        XCTAssertTrue(LandscapeCount.turnsSideways(CGSize(width: 1920, height: 1080)))
        XCTAssertFalse(LandscapeCount.turnsSideways(CGSize(width: 1080, height: 1920)))
        XCTAssertFalse(LandscapeCount.turnsSideways(CGSize(width: 1080, height: 1080)))
        XCTAssertFalse(LandscapeCount.turnsSideways(.zero))
    }
}
