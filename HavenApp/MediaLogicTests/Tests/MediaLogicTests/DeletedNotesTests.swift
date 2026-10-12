import XCTest
@testable import MediaLogic

/// Your own kind-5 requests keep their targets off every screen.
final class DeletedNotesTests: XCTestCase {
    private struct Note: DeletableNote, Equatable {
        let id: String
        var repostedEventId: String? = nil
    }

    private let me = String(repeating: "a", count: 64)
    private let gone = String(repeating: "1", count: 64)
    private let other = String(repeating: "2", count: 64)

    func testRequestTargetsAreItsHexETags() {
        let tags = [["e", gone.uppercased()], ["e", "not-an-id"], ["p", other], ["k", "1"], ["e"]]
        XCTAssertEqual(DeletedNotes.targets(ofRequestTags: tags), [gone])
    }

    func testOnlyYourOwnRequestCounts() {
        XCTAssertTrue(DeletedNotes.isOwnRequest(kind: 5, pubkey: me, owner: me))
        XCTAssertFalse(DeletedNotes.isOwnRequest(kind: 5, pubkey: other, owner: me))
        XCTAssertFalse(DeletedNotes.isOwnRequest(kind: 1, pubkey: me, owner: me))
        XCTAssertFalse(DeletedNotes.isOwnRequest(kind: 5, pubkey: "", owner: ""))
    }

    private func request(pubkey: String, kind: Int = 5) -> [String: Any] {
        ["id": String(repeating: "e", count: 64), "kind": kind, "pubkey": pubkey,
         "tags": [["e", gone]], "content": "", "sig": String(repeating: "f", count: 128)]
    }

    func testYourOwnSignedRequestCounts() {
        XCTAssertTrue(DeletedNotes.isOwnSignedRequest(request(pubkey: me), owner: me) { _ in true })
    }

    /// A relay in the feed set can send a kind 5 under the owner's pubkey
    /// naming any post. With a bad `sig` or a changed `id` it marks nothing.
    func testRequestThatFailsVerificationMarksNothing() {
        var verified = 0
        XCTAssertFalse(DeletedNotes.isOwnSignedRequest(request(pubkey: me), owner: me) { _ in verified += 1; return false })
        XCTAssertEqual(verified, 1, "the signature is checked, not assumed")
    }

    func testSomeoneElsesRequestIsDroppedBeforeVerification() {
        var verified = 0
        XCTAssertFalse(DeletedNotes.isOwnSignedRequest(request(pubkey: other), owner: me) { _ in verified += 1; return true })
        XCTAssertFalse(DeletedNotes.isOwnSignedRequest(request(pubkey: me, kind: 1), owner: me) { _ in verified += 1; return true })
        XCTAssertFalse(DeletedNotes.isOwnSignedRequest(["tags": [["e", gone]]], owner: me) { _ in verified += 1; return true })
        XCTAssertEqual(verified, 0)
    }

    func testDeletedPostAndItsRepostsAreHidden() {
        let deleted: Set<String> = [gone]
        XCTAssertTrue(DeletedNotes.hides(Note(id: gone), deleted: deleted))
        XCTAssertTrue(DeletedNotes.hides(Note(id: other, repostedEventId: gone), deleted: deleted))
        XCTAssertFalse(DeletedNotes.hides(Note(id: other), deleted: deleted))
        XCTAssertFalse(DeletedNotes.hides(Note(id: gone), deleted: []))
    }

    func testVisibleNotesDropOnlyTheDeleted() {
        let keep = Note(id: other)
        let repost = Note(id: "r", repostedEventId: gone)
        XCTAssertEqual(DeletedNotes.visible([keep, Note(id: gone), repost], deleted: [gone]), [keep])
        XCTAssertEqual(DeletedNotes.visible([keep, Note(id: gone)], deleted: []), [keep, Note(id: gone)])
    }

    func testVisibleCacheDropsTheDeletedUnderAnyKey() {
        let keep = Note(id: other)
        // The deleted id as a key for another note (a reply hint): a lookup by
        // the deleted id must not find anything either.
        let cache = [other: keep, gone: Note(id: "3"), "hint": Note(id: gone), "r": Note(id: "r", repostedEventId: gone)]
        XCTAssertEqual(DeletedNotes.visible(cache, deleted: [gone]), [other: keep])
    }
}
