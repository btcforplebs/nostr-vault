import XCTest
@testable import MediaLogic

final class PullDownToCloseRuleTests: XCTestCase {
    func testPullFromTopPastDistanceCloses() {
        XCTAssertTrue(PullDownToCloseRule.shouldClose(startedAtTop: true, overscrollAtRelease: 120, dragAtRelease: 240))
        XCTAssertTrue(PullDownToCloseRule.shouldClose(startedAtTop: true,
                                                      overscrollAtRelease: PullDownToCloseRule.closeDistance,
                                                      dragAtRelease: 180))
    }

    func testShortPullFromTopStays() {
        XCTAssertFalse(PullDownToCloseRule.shouldClose(startedAtTop: true, overscrollAtRelease: 40, dragAtRelease: 80))
        XCTAssertFalse(PullDownToCloseRule.shouldClose(startedAtTop: true, overscrollAtRelease: 0, dragAtRelease: 0))
    }

    /// Scrolling up from mid-page and running past the top only scrolls.
    func testPullThatBeganMidPageNeverCloses() {
        XCTAssertFalse(PullDownToCloseRule.shouldClose(startedAtTop: false, overscrollAtRelease: 300, dragAtRelease: 600))
    }

    /// In a sheet the sheet moves, not the content: the finger's travel counts.
    func testLongDragInSheetCloses() {
        XCTAssertTrue(PullDownToCloseRule.shouldClose(startedAtTop: true, overscrollAtRelease: 0,
                                                      dragAtRelease: PullDownToCloseRule.closeDrag))
        XCTAssertFalse(PullDownToCloseRule.shouldClose(startedAtTop: true, overscrollAtRelease: 0,
                                                       dragAtRelease: 120))
    }

    /// A pull that scrolled the page down off its top is not a close.
    func testDragThatScrolledAwayFromTopStays() {
        XCTAssertFalse(PullDownToCloseRule.shouldClose(startedAtTop: true, overscrollAtRelease: -200,
                                                       dragAtRelease: 300))
    }

    func testAtTop() {
        XCTAssertTrue(PullDownToCloseRule.isAtTop(overscroll: 0))
        XCTAssertTrue(PullDownToCloseRule.isAtTop(overscroll: -0.5))
        XCTAssertTrue(PullDownToCloseRule.isAtTop(overscroll: 30))
        XCTAssertFalse(PullDownToCloseRule.isAtTop(overscroll: -20))
    }
}
