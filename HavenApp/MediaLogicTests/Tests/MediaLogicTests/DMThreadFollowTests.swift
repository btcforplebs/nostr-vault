import XCTest
@testable import MediaLogic

/// A3 in RESEARCH/NV_MESSAGES_UX_CHECK_2026_11_18.md: reading older messages,
/// a new message must not yank the chat to the bottom. At the bottom it still
/// follows, and your own sent message always brings you down.
final class DMThreadFollowTests: XCTestCase {
    func testScrolledUpTheirNewMessageStaysPut() {
        XCTAssertFalse(DMThreadFollow.shouldFollow(wasNearBottom: false, previousNewestID: "a", newestID: "b", newestIsFromMe: false))
    }

    func testAtBottomTheirNewMessageFollows() {
        XCTAssertTrue(DMThreadFollow.shouldFollow(wasNearBottom: true, previousNewestID: "a", newestID: "b", newestIsFromMe: false))
    }

    func testScrolledUpMySentMessageFollows() {
        XCTAssertTrue(DMThreadFollow.shouldFollow(wasNearBottom: false, previousNewestID: "a", newestID: "b", newestIsFromMe: true))
    }

    func testScrolledUpOlderMessagesLoadedAboveStayPut() {
        // Newest unchanged (older ones prepended), even if that newest is mine.
        XCTAssertFalse(DMThreadFollow.shouldFollow(wasNearBottom: false, previousNewestID: "b", newestID: "b", newestIsFromMe: true))
    }

    func testFirstMessagesArriveIntoEmptyChat() {
        XCTAssertTrue(DMThreadFollow.shouldFollow(wasNearBottom: true, previousNewestID: nil, newestID: "a", newestIsFromMe: false))
        XCTAssertFalse(DMThreadFollow.shouldFollow(wasNearBottom: false, previousNewestID: "a", newestID: nil, newestIsFromMe: false))
    }

    func testNearBottomSlack() {
        // End marker on screen, or just below within the slack: at the bottom.
        XCTAssertTrue(DMThreadFollow.isNearBottom(bottomMarkerY: 500, visibleHeight: 600))
        XCTAssertTrue(DMThreadFollow.isNearBottom(bottomMarkerY: 600 + DMThreadFollow.nearBottomSlack, visibleHeight: 600))
        // Scrolled up past the slack: reading older messages.
        XCTAssertFalse(DMThreadFollow.isNearBottom(bottomMarkerY: 600 + DMThreadFollow.nearBottomSlack + 1, visibleHeight: 600))
        XCTAssertFalse(DMThreadFollow.isNearBottom(bottomMarkerY: 2400, visibleHeight: 600))
    }
}
