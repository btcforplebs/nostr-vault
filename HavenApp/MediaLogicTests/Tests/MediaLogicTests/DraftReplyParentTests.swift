import XCTest
@testable import MediaLogic

/// A saved reply draft names the note it answers, and a resumed one stays a
/// reply even before the parent has loaded.
final class DraftReplyParentTests: XCTestCase {
    private let parent = "p".padding(toLength: 64, withPad: "a", startingAt: 0)
    private let other = String(repeating: "b", count: 64)
    private let root = String(repeating: "c", count: 64)
    private let parentId = String(repeating: "d", count: 64)

    /// Tags as DraftService.saveDraftLocally writes them for a reply inside a thread.
    private var savedTags: [[String]] {
        [["d", "x"], ["k", "1"], ["e", root, "wss://r", "root"], ["e", parentId, "wss://r", "reply"],
         ["p", parent], ["p", other], ["p", parent]]
    }

    func testParentAuthorIsTheFirstPTag() {
        XCTAssertEqual(DraftReplyParent.parentPubkey(replyToId: parentId, tags: savedTags), parent)
    }

    func testANewNoteDraftHasNoParent() {
        XCTAssertNil(DraftReplyParent.parentPubkey(replyToId: nil, tags: savedTags))
    }

    func testStandInKeepsTheThreadRootAndPeopleOnce() {
        let tags = DraftReplyParent.standInTags(replyToId: parentId, rootId: root, parentPubkey: parent, tags: savedTags)
        XCTAssertEqual(tags, [["e", root, "", "root"], ["p", other]])
    }

    func testStandInForAReplyToARootNoteHasNoETag() {
        // The parent was the thread's first note: posting then makes it the root.
        let tags = DraftReplyParent.standInTags(replyToId: parentId, rootId: nil, parentPubkey: parent, tags: [["p", parent]])
        XCTAssertTrue(tags.isEmpty)
        XCTAssertTrue(DraftReplyParent.standInTags(replyToId: parentId, rootId: parentId, parentPubkey: parent, tags: []).isEmpty)
    }

    func testLineShowsTheFirstNonEmptyLineOfTheirNote() {
        XCTAssertEqual(DraftReplyParent.line(name: "Logen", parentContent: "\n  gm everyone  \nsecond line"), "↩ Logen: gm everyone")
    }

    func testLineBeforeTheNoteLoads() {
        XCTAssertEqual(DraftReplyParent.line(name: "Logen", parentContent: nil), "↩ Reply to Logen")
        XCTAssertEqual(DraftReplyParent.line(name: "Logen", parentContent: "  \n "), "↩ Reply to Logen")
    }
}
