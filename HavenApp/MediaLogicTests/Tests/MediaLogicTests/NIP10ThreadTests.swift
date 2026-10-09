import XCTest
@testable import MediaLogic

final class NIP10ThreadTests: XCTestCase {
    private func parent(_ tags: [[String]]) -> String? { NIP10Thread.parentEventId(kind: 1, tags: tags) }

    func testQuoteIsNotAReply() {
        // A Primal quote: its only e tag is the quoted note, marked "mention".
        XCTAssertNil(parent([["e", "quoted", "", "mention"], ["client", "Primal iOS"]]))
    }

    func testReplyMarkerWins() {
        XCTAssertEqual(parent([["e", "root", "", "root"], ["e", "parent", "", "reply"]]), "parent")
    }

    func testReplyThatAlsoQuotesPointsAtItsParent() {
        // The mention comes last; positional reading used to pick it.
        XCTAssertEqual(parent([["e", "root", "", "root"], ["e", "parent", "", "reply"], ["e", "quoted", "", "mention"]]), "parent")
    }

    func testDirectReplyToRootWithOnlyARootMarker() {
        XCTAssertEqual(parent([["e", "root", "wss://r", "root"], ["e", "quoted", "", "mention"]]), "root")
    }

    func testPositionalLastUnmarkedTag() {
        XCTAssertEqual(parent([["e", "root"], ["e", "parent"]]), "parent")
        XCTAssertEqual(parent([["e", "root"], ["e", "parent"], ["e", "quoted", "", "mention"]]), "parent")
    }

    func testNoETags() {
        XCTAssertNil(parent([["p", "someone"], ["t", "nostr"]]))
    }

    // MARK: - NIP-22 comments

    /// An Amethyst-style comment answering another comment under a kind 1 note.
    private let nestedComment: [[String]] = [
        ["E", "root", "wss://r", "rootauthor"], ["K", "1"], ["P", "rootauthor"],
        ["e", "parentcomment", "wss://r", "parentauthor"], ["k", "1111"], ["p", "parentauthor"],
    ]

    func testCommentParentIsLowercaseE() {
        // The fourth slot is a pubkey, not a NIP-10 marker; it must not matter.
        XCTAssertEqual(NIP10Thread.parentEventId(kind: 1111, tags: nestedComment), "parentcomment")
    }

    func testCommentOnAnAddressHasNoParentEvent() {
        XCTAssertNil(NIP10Thread.parentEventId(kind: 1111, tags: [["A", "30023:pk:d"], ["a", "30023:pk:d"], ["k", "30023"]]))
    }

    func testRootEventId() {
        XCTAssertEqual(NIP10Thread.rootEventId(kind: 1111, tags: nestedComment), "root")
        XCTAssertEqual(NIP10Thread.rootEventId(kind: 1, tags: [["e", "quoted", "", "mention"], ["e", "root", "", "root"], ["e", "parent", "", "reply"]]), "root")
        XCTAssertEqual(NIP10Thread.rootEventId(kind: 1, tags: [["e", "root"], ["e", "parent"]]), "root")
        XCTAssertNil(NIP10Thread.rootEventId(kind: 1, tags: [["e", "quoted", "", "mention"]]))
    }

    func testOnlyCommentsOnNotesAreNoteComments() {
        XCTAssertTrue(NIP10Thread.isNoteComment(kind: 1111, tags: nestedComment))
        XCTAssertFalse(NIP10Thread.isNoteComment(kind: 1111, tags: [["E", "v"], ["K", "21"], ["e", "v"], ["k", "21"]]))
        XCTAssertFalse(NIP10Thread.isNoteComment(kind: 1, tags: [["K", "1"]]))
    }

    func testReplyKindMatchesTheParent() {
        XCTAssertEqual(NIP10Thread.replyKind(parentKind: 1111), 1111)
        XCTAssertEqual(NIP10Thread.replyKind(parentKind: 1), 1)
    }

    func testCommentReplyTagsKeepRootAndNameTheParent() {
        let tags = NIP10Thread.commentReplyTags(parentId: "c2", parentPubkey: "author2", parentTags: nestedComment, relayHint: "wss://me")
        XCTAssertEqual(tags, [
            ["E", "root", "wss://r", "rootauthor"], ["K", "1"], ["P", "rootauthor"],
            ["e", "c2", "wss://me", "author2"], ["k", "1111"], ["p", "author2"],
        ])
        XCTAssertEqual(NIP10Thread.parentEventId(kind: 1111, tags: tags), "c2")
        XCTAssertEqual(NIP10Thread.rootEventId(kind: 1111, tags: tags), "root")
    }
}
