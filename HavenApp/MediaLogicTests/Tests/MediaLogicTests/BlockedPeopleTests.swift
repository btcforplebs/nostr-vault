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

    private let serviceHex = String(repeating: "5", count: 64)

    /// A followed person quoting someone you blocked: the quote is hidden.
    func testQuoteOfBlockedPersonIsHidden() {
        XCTAssertFalse(BlockedPeople.showsQuote(author: blockedHex, kind: 1, tags: [], blocked: [blockedHex]))
        XCTAssertFalse(BlockedPeople.showsQuote(author: blockedHex.uppercased(), kind: 1, tags: [], blocked: [blockedHex]))
    }

    /// Positive control, and unblocking: the same quote shows again.
    func testQuoteShowsWhenAuthorNotBlocked() {
        XCTAssertTrue(BlockedPeople.showsQuote(author: friendHex, kind: 1, tags: [], blocked: [blockedHex]))
        XCTAssertTrue(BlockedPeople.showsQuote(author: blockedHex, kind: 1, tags: [], blocked: []))
    }

    private func hostTags(_ host: String) -> [[String]] {
        [["d", "stream"], ["p", host, "", "Host"]]
    }

    /// zap.stream signs with its own key; the blocked streamer is only the
    /// Host p tag. Their quoted stream is still hidden.
    func testServiceSignedStreamOfBlockedHostIsHidden() {
        XCTAssertFalse(BlockedPeople.showsQuote(author: serviceHex, kind: 30311,
                                                tags: hostTags(blockedHex), blocked: [blockedHex]))
    }

    /// Positive control: the same service's stream for someone not blocked shows.
    func testServiceSignedStreamOfUnblockedHostShows() {
        XCTAssertTrue(BlockedPeople.showsQuote(author: serviceHex, kind: 30311,
                                               tags: hostTags(friendHex), blocked: [blockedHex]))
    }

    /// Blocking the service key itself still hides its streams.
    func testStreamFromBlockedSignerIsHidden() {
        XCTAssertFalse(BlockedPeople.showsQuote(author: blockedHex, kind: 30311,
                                                tags: hostTags(friendHex), blocked: [blockedHex]))
    }
}

/// Blocking someone from a thread page: their notes leave it at once, and the
/// note shown full size gives way if it is theirs.
final class BlockedPeopleThreadTests: XCTestCase {
    private let blockedHex = String(repeating: "b", count: 64)
    private let friendHex = String(repeating: "f", count: 64)

    private struct Note { let id: String; let pubkey: String }

    func testBlockedPersonsQuotesAndParentsAreLeftOut() {
        let notes = [Note(id: "1", pubkey: friendHex), Note(id: "2", pubkey: blockedHex),
                     Note(id: "3", pubkey: blockedHex.uppercased())]
        let shown = BlockedPeople.visibleNotes(notes, blocked: [blockedHex]) { $0.pubkey }
        XCTAssertEqual(shown.map(\.id), ["1"])
    }

    func testNothingIsLeftOutWithNoBlocks() {
        let notes = [Note(id: "1", pubkey: friendHex), Note(id: "2", pubkey: blockedHex)]
        XCTAssertEqual(BlockedPeople.visibleNotes(notes, blocked: []) { $0.pubkey }.map(\.id), ["1", "2"])
    }

    func testOpenedNoteByBlockedPersonBecomesAPlaceholder() {
        XCTAssertEqual(BlockedPeople.focusedNote(author: blockedHex, isOpenedNote: true, blocked: [blockedHex]),
                       .placeholder)
    }

    func testTappedIntoReplyByBlockedPersonGoesBackToTheOpenedNote() {
        XCTAssertEqual(BlockedPeople.focusedNote(author: blockedHex, isOpenedNote: false, blocked: [blockedHex]),
                       .backToOpened)
    }

    func testNoteBySomeoneElseStaysShown() {
        XCTAssertEqual(BlockedPeople.focusedNote(author: friendHex, isOpenedNote: true, blocked: [blockedHex]),
                       .shown)
        XCTAssertEqual(BlockedPeople.focusedNote(author: blockedHex, isOpenedNote: true, blocked: []),
                       .shown)
    }
}
