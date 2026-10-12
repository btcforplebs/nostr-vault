import XCTest
@testable import MediaLogic

/// Deleting one of your posts drops it from the local event list.
final class NoteDeletionTests: XCTestCase {
    private struct Post: Identifiable, Equatable { let id: String }

    func testRequestNamesThePost() {
        XCTAssertEqual(NoteDeletion.requestTags(noteId: "abc"), [["e", "abc"]])
    }

    func testDeletedPostLeavesTheListAndNothingElseDoes() {
        let events = [Post(id: "keep1"), Post(id: "gone"), Post(id: "keep2")]
        XCTAssertEqual(NoteDeletion.without(events, noteId: "gone").map(\.id), ["keep1", "keep2"])
    }

    func testUnknownIdChangesNothing() {
        let events = [Post(id: "keep1"), Post(id: "keep2")]
        XCTAssertEqual(NoteDeletion.without(events, noteId: "missing"), events)
    }
}
