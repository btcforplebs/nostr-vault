import XCTest
@testable import MediaLogic

final class PullDownToCloseRuleTests: XCTestCase {
    func testPullFromTopPastDistanceCloses() {
        XCTAssertTrue(PullDownToCloseRule.shouldClose(startedAtTop: true, overscrollAtRelease: 120))
        XCTAssertTrue(PullDownToCloseRule.shouldClose(startedAtTop: true,
                                                      overscrollAtRelease: PullDownToCloseRule.closeDistance))
    }

    func testShortPullFromTopStays() {
        XCTAssertFalse(PullDownToCloseRule.shouldClose(startedAtTop: true, overscrollAtRelease: 40))
        XCTAssertFalse(PullDownToCloseRule.shouldClose(startedAtTop: true, overscrollAtRelease: 0))
    }

    /// Scrolling up from mid-page and running past the top only scrolls.
    func testPullThatBeganMidPageNeverCloses() {
        XCTAssertFalse(PullDownToCloseRule.shouldClose(startedAtTop: false, overscrollAtRelease: 300))
    }

    func testAtTop() {
        XCTAssertTrue(PullDownToCloseRule.isAtTop(overscroll: 0))
        XCTAssertTrue(PullDownToCloseRule.isAtTop(overscroll: -0.5))
        XCTAssertTrue(PullDownToCloseRule.isAtTop(overscroll: 30))
        XCTAssertFalse(PullDownToCloseRule.isAtTop(overscroll: -20))
    }
}
