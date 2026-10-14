import XCTest
@testable import MediaLogic

/// A block on DMs: the opened message's real sender is checked, conversations
/// with a blocked person are hidden (not deleted), and they never alert.
final class BlockedPeopleTests: XCTestCase {
    private let blockedHex = String(repeating: "b", count: 64)
    private let friendHex = String(repeating: "f", count: 64)

    private struct Convo { let id: String }

    func testConversationWithBlockedPersonIsHidden() {
        let all = [Convo(id: friendHex), Convo(id: blockedHex)]
        let shown = BlockedPeople.visibleConversations(all, blocked: [blockedHex]) { $0.id }
        XCTAssertEqual(shown.map(\.id), [friendHex])
    }

    /// Unblocking is just an empty block list: the stored conversation is
    /// shown again because nothing was removed.
    func testUnblockShowsTheConversationAgain() {
        let all = [Convo(id: friendHex), Convo(id: blockedHex)]
        let shown = BlockedPeople.visibleConversations(all, blocked: []) { $0.id }
        XCTAssertEqual(shown.map(\.id), [friendHex, blockedHex])
    }

    func testBlockedSenderNeverAlerts() {
        XCTAssertFalse(BlockedPeople.mayAlert(sender: blockedHex, isFromMe: false, blocked: [blockedHex]))
    }

    /// Positive control: the same message from someone not blocked does.
    func testUnblockedSenderAlerts() {
        XCTAssertTrue(BlockedPeople.mayAlert(sender: friendHex, isFromMe: false, blocked: [blockedHex]))
    }

    func testOwnCopyNeverAlerts() {
        XCTAssertFalse(BlockedPeople.mayAlert(sender: friendHex, isFromMe: true, blocked: []))
    }

    /// Block lists hold lowercase hex; a sender in upper case is still caught.
    func testSenderCaseDoesNotEscapeTheBlock() {
        XCTAssertTrue(BlockedPeople.isBlocked(blockedHex.uppercased(), in: [blockedHex]))
        XCTAssertFalse(BlockedPeople.isBlocked("", in: [blockedHex]))
    }

    /// A followed person quoting someone you blocked: the quote is hidden.
    func testQuoteOfBlockedPersonIsHidden() {
        XCTAssertFalse(BlockedPeople.showsQuote(author: blockedHex, blocked: [blockedHex]))
        XCTAssertFalse(BlockedPeople.showsQuote(author: blockedHex.uppercased(), blocked: [blockedHex]))
    }

    /// Positive control, and unblocking: the same quote shows again.
    func testQuoteShowsWhenAuthorNotBlocked() {
        XCTAssertTrue(BlockedPeople.showsQuote(author: friendHex, blocked: [blockedHex]))
        XCTAssertTrue(BlockedPeople.showsQuote(author: blockedHex, blocked: []))
    }
}
