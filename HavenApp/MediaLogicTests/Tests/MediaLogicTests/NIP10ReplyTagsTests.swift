import XCTest
@testable import MediaLogic

/// The reply tags Post signs and the composer preview draws, from one
/// definition (moved out of ComposeView+Posting, 2026-11-27).
final class NIP10ReplyTagsTests: XCTestCase {
    let a = String(repeating: "a", count: 64), b = String(repeating: "b", count: 64), c = String(repeating: "c", count: 64)

    func testReplyToARootNote() {
        let r = NIP10Thread.replyTags(parentId: "p1", parentPubkey: a, parentTags: [["p", c]], parentKind: 1, relayHint: "wss://h")
        XCTAssertEqual(r.kind, 1)
        XCTAssertEqual(r.tags, [["e", "p1", "wss://h", "root", a], ["p", a], ["p", c]])
        XCTAssertEqual(NIP10Thread.parentEventId(kind: r.kind, tags: r.tags), "p1")
        XCTAssertEqual(NIP10Thread.parentAuthor(kind: r.kind, tags: r.tags), a)
    }

    func testReplyToAReplyKeepsTheRoot() {
        let r = NIP10Thread.replyTags(parentId: "p2", parentPubkey: a,
                                      parentTags: [["e", "root", "", "root", b], ["e", "q", "", "mention"], ["p", b], ["p", a]],
                                      parentKind: 1, relayHint: "")
        XCTAssertEqual(r.kind, 1)
        XCTAssertEqual(r.tags, [["e", "root", "", "root", b], ["e", "p2", "", "reply", a], ["p", a], ["p", b]])
        XCTAssertEqual(NIP10Thread.parentEventId(kind: r.kind, tags: r.tags), "p2")
    }

    func testReplyToANonNoteIsAComment() {
        let r = NIP10Thread.replyTags(parentId: "art", parentPubkey: a, parentTags: [["d", "x"]], parentKind: 30023, relayHint: "")
        XCTAssertEqual(r.kind, NIP10Thread.commentKind)
        XCTAssertEqual(r.tags, NIP10Thread.commentTags(parentId: "art", parentKind: 30023, parentPubkey: a, parentTags: [["d", "x"]], relayHint: ""))
    }
}
