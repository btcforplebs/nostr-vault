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
        let cache = [other: keep, gone: Note(id: gone), "hint": Note(id: gone)]
        XCTAssertEqual(DeletedNotes.visible(cache, deleted: [gone]), [other: keep])
    }
}
