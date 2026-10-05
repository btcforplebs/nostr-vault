import XCTest
@testable import MediaLogic

/// The threads spec Logen shared on 2026-10-03, with Tom's default for notes.
final class ThreadSpecTests: XCTestCase {
    let id = String(repeating: "a", count: 64)
    let pk = String(repeating: "b", count: 64)

    func testReplyKindTable() {
        XCTAssertEqual(NIP10Thread.replyKind(parentKind: 1), 1, "note → kind 1 by default")
        XCTAssertEqual(NIP10Thread.replyKind(parentKind: 1, asComment: true), 1111, "note → comment when asked")
        XCTAssertEqual(NIP10Thread.replyKind(parentKind: 1111), 1111)
        XCTAssertEqual(NIP10Thread.replyKind(parentKind: 30023), 1111, "kind 1 replies are only valid onto kind 1")
        XCTAssertEqual(NIP10Thread.replyKind(parentKind: 34236), 1111)
        XCTAssertEqual(NIP10Thread.replyKind(parentKind: 20), 1111)
    }

    func testOriginalNoteOnlyForUnthreadedKind1() {
        XCTAssertTrue(NIP10Thread.isOriginalNote(kind: 1, tags: [["p", pk]]))
        XCTAssertTrue(NIP10Thread.isOriginalNote(kind: 1, tags: [["e", id, "", "mention"]]), "a quote is still an original")
        XCTAssertFalse(NIP10Thread.isOriginalNote(kind: 1, tags: [["e", id, "", "root"]]))
        XCTAssertFalse(NIP10Thread.isOriginalNote(kind: 30023, tags: []))
    }

    func testCommentOnRegularEvent() {
        let tags = NIP10Thread.commentTags(parentId: id, parentKind: 1, parentPubkey: pk, parentTags: [], relayHint: "wss://r")
        XCTAssertEqual(tags, [
            ["E", id, "wss://r", pk], ["K", "1"], ["P", pk],
            ["e", id, "wss://r", pk], ["k", "1"], ["p", pk],
        ])
    }

    func testCommentOnArticleIsRootedByAOnly() {
        let tags = NIP10Thread.commentTags(parentId: id, parentKind: 30023, parentPubkey: pk,
                                           parentTags: [["d", "my-post"], ["title", "T"]], relayHint: "")
        let coord = "30023:\(pk):my-post"
        XCTAssertEqual(tags, [
            ["A", coord, ""], ["K", "30023"], ["P", pk],
            ["a", coord, ""], ["e", id, "", pk], ["k", "30023"], ["p", pk],
        ])
        XCTAssertFalse(tags.contains { $0[0] == "E" }, "no required root E on addressables")
    }

    func testReplaceableKeepsTrailingColon() {
        XCTAssertEqual(NIP10Thread.coordinate(kind: 0, pubkey: pk, tags: []), "0:\(pk):")
        XCTAssertEqual(NIP10Thread.coordinate(kind: 10002, pubkey: pk, tags: []), "10002:\(pk):")
        XCTAssertNil(NIP10Thread.coordinate(kind: 1, pubkey: pk, tags: []))
        XCTAssertNil(NIP10Thread.coordinate(kind: 30023, pubkey: pk, tags: []), "addressable without d")
    }

    func testNestedCommentCopiesRootAndPointsAtParent() {
        let rootTags = NIP10Thread.commentTags(parentId: id, parentKind: 30023, parentPubkey: pk,
                                               parentTags: [["d", "x"]], relayHint: "")
        let commentId = String(repeating: "c", count: 64), commenter = String(repeating: "d", count: 64)
        let nested = NIP10Thread.commentTags(parentId: commentId, parentKind: 1111, parentPubkey: commenter,
                                             parentTags: rootTags, relayHint: "")
        XCTAssertTrue(nested.contains(["A", "30023:\(pk):x", ""]))
        XCTAssertTrue(nested.contains(["K", "30023"]))
        XCTAssertTrue(nested.contains(["e", commentId, "", commenter]))
        XCTAssertTrue(nested.contains(["k", "1111"]))
        XCTAssertTrue(nested.contains(["p", commenter]))
        XCTAssertFalse(nested.contains { $0[0] == "a" }, "lowercase a belonged to the old parent")
        XCTAssertEqual(NIP10Thread.parentEventId(kind: 1111, tags: nested), commentId)
    }
}

final class ThreadReplyVisibilityTests: XCTestCase {
    func testOutsideNeedsALoadedGraph() {
        XCTAssertFalse(ThreadReplyVisibility.isOutside("stranger", trusted: [], insiders: []))
        XCTAssertTrue(ThreadReplyVisibility.isOutside("stranger", trusted: ["friend"], insiders: []))
        XCTAssertFalse(ThreadReplyVisibility.isOutside("friend", trusted: ["friend"], insiders: []))
        // The opened note's author is never folded, trusted or not.
        XCTAssertFalse(ThreadReplyVisibility.isOutside("op", trusted: ["friend"], insiders: ["op"]))
    }

    func testDescendantsReachEveryDepthOnly() {
        struct N { let id: String; let parent: String? }
        let notes = [N(id: "a", parent: "root"), N(id: "b", parent: "a"), N(id: "c", parent: "b"),
                     N(id: "x", parent: "other"), N(id: "root", parent: nil)]
        let ids = ThreadReplyVisibility.descendants(of: "root", in: notes, id: \.id, parentId: \.parent).map(\.id)
        XCTAssertEqual(Set(ids), ["a", "b", "c"])
    }
}
