import XCTest
@testable import MediaLogic

/// Discover shows the wider web minus follows. A note that only tags the
/// owner must not get in from a key outside the web (WoT leak 2026-11-11 §4).
final class DiscoverAuthorTests: XCTestCase {
    private let owner = String(repeating: "0", count: 64)
    private let stranger = String(repeating: "a", count: 64)
    private let widerWeb = String(repeating: "b", count: 64)
    private let follow = String(repeating: "c", count: 64)
    private let ownerPost = String(repeating: "d", count: 64)

    private func reply(from author: String, id: String) -> FeedNote {
        FeedNote(id: id, pubkey: author, content: "hey, check this out", createdAt: Date(),
                 tags: [["e", ownerPost, "", "reply"], ["p", owner]], kind: 1)
    }

    private func discover(_ notes: [FeedNote]) -> [String] {
        FeedFilterEngine.filterFeedNotes(
            notes: notes, mode: .discovery, blocked: [], showReposts: true, showReplies: true,
            followedPubkeys: [follow], wotPubkeys: [widerWeb, follow], popularFilter: .all, popularNoteScores: [:]
        ).map(\.id)
    }

    func testReplyTaggingOwnerFromOutsideTheWebIsDropped() {
        XCTAssertEqual(discover([reply(from: stranger, id: "s")]), [])
    }

    func testWiderWebAuthorStillShows() {
        XCTAssertEqual(discover([reply(from: widerWeb, id: "w")]), ["w"])
    }

    func testFollowIsLeftToFollowing() {
        XCTAssertEqual(discover([reply(from: follow, id: "f")]), [])
    }

    func testRepostJudgedByReposter() {
        let bare = FeedNote(id: "r", pubkey: stranger, content: "", createdAt: Date(),
                            tags: [["e", ownerPost]], kind: 6, repostedBy: stranger)
        XCTAssertEqual(discover([bare]), [])
    }
}
