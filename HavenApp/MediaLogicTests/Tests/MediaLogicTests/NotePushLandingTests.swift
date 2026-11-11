import XCTest
@testable import MediaLogic

/// A Vault note push that never shows its screen falls back to a sheet.
final class NotePushLandingTests: XCTestCase {
    func testALandedPushIsNotAMiss() {
        var landing = NotePushLanding()
        landing.began("a")
        landing.landed("a")
        XCTAssertFalse(landing.missed("a"))
    }

    func testAPushThatNeverLandedIsAMissOnce() {
        var landing = NotePushLanding()
        landing.began("a")
        XCTAssertTrue(landing.missed("a"))
        XCTAssertFalse(landing.missed("a"), "the fallback opens one sheet, not two")
    }

    func testAnotherScreenLandingDoesNotCount() {
        var landing = NotePushLanding()
        landing.began("a")
        landing.landed("b")
        XCTAssertTrue(landing.missed("a"))
    }

    func testANewerPushReplacesTheOlderCheck() {
        var landing = NotePushLanding()
        landing.began("a")
        landing.began("b")
        XCTAssertFalse(landing.missed("a"), "only the latest push is watched")
        XCTAssertTrue(landing.missed("b"))
    }

    func testNothingPendingIsNeverAMiss() {
        var landing = NotePushLanding()
        XCTAssertFalse(landing.missed("a"))
    }
}
