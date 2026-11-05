import XCTest
@testable import MediaLogic

/// A DM into the thread that is open on screen is read as it arrives.
final class DMUnreadRuleTests: XCTestCase {
    func testMessageIntoTheOpenThreadIsNotUnread() {
        XCTAssertFalse(DMUnreadRule.countsAsUnread(mayAlert: true, conversation: "aa",
                                                   visibleConversation: "aa", appInForeground: true))
    }

    func testMessageIntoAnotherThreadIsUnread() {
        XCTAssertTrue(DMUnreadRule.countsAsUnread(mayAlert: true, conversation: "aa",
                                                  visibleConversation: "bb", appInForeground: true))
        XCTAssertTrue(DMUnreadRule.countsAsUnread(mayAlert: true, conversation: "aa",
                                                  visibleConversation: nil, appInForeground: true))
    }

    /// The thread left open with the app in the background was not seen.
    func testOpenThreadInTheBackgroundStillCounts() {
        XCTAssertTrue(DMUnreadRule.countsAsUnread(mayAlert: true, conversation: "aa",
                                                  visibleConversation: "aa", appInForeground: false))
    }

    /// Your own copies and blocked senders never count (BlockedPeople.mayAlert).
    func testNeverUnreadWhenItMayNotAlert() {
        XCTAssertFalse(DMUnreadRule.countsAsUnread(mayAlert: false, conversation: "aa",
                                                   visibleConversation: nil, appInForeground: false))
    }
}
