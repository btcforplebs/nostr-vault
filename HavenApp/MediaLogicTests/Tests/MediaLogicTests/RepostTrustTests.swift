import XCTest
@testable import MediaLogic

/// A kind 6 can embed any JSON with any `pubkey`. Only a verified embedded
/// event lends the row its author, and Global trusts the repost's signer.
final class RepostTrustTests: XCTestCase {
    private let stranger = String(repeating: "a", count: 64)
    private let trusted = String(repeating: "b", count: 64)
    private let originalId = String(repeating: "c", count: 64)

    private var forgedContent: String {
        #"{"id":"\#(originalId)","kind":1,"pubkey":"\#(trusted)","created_at":1700000000,"tags":[],"content":"send sats to X","sig":"00"}"#
    }

    private func repost(verify: (String) -> Bool) -> FeedNote {
        FeedNote(id: "r", pubkey: stranger, content: forgedContent, createdAt: Date(),
                 tags: [["e", originalId], ["p", trusted]], kind: 6, repostedBy: stranger, verify: verify)
    }

    private func global(_ notes: [FeedNote]) -> [FeedNote] {
        // showReposts must be true: false drops every kind 6 and would pass
        // this without the fix.
        FeedFilterEngine.filterFeedNotes(
            notes: notes, mode: .global, blocked: [], showReposts: true, showReplies: true,
            followedPubkeys: [], wotPubkeys: [trusted], popularFilter: .all, popularNoteScores: [:]
        )
    }

    func testStrangersRepostIsNotAdmittedByTheAuthorItNames() {
        XCTAssertEqual(global([repost(verify: { _ in true })]).count, 0, "verified or not, the signer is a stranger")
        XCTAssertEqual(global([repost(verify: { _ in false })]).count, 0)
    }

    func testUnverifiedEmbedStaysBare() {
        let note = repost(verify: { _ in false })
        XCTAssertEqual(note.pubkey, stranger)
        XCTAssertEqual(note.content, "")
        XCTAssertEqual(note.repostedEventId, originalId, "the row still fetches the real original")
        XCTAssertEqual(note.tags.first?.first, "e", "outer tags kept, so it still reads as bare")
        XCTAssertNil(note.originalCreatedAt)
    }

    func testVerifiedEmbedStillUnpacks() {
        var seen: String?
        let note = repost(verify: { json in seen = json; return true })
        XCTAssertEqual(seen, forgedContent, "verifies the raw content, not a re-serialized copy")
        XCTAssertEqual(note.pubkey, trusted)
        XCTAssertEqual(note.content, "send sats to X")
        XCTAssertEqual(note.repostedBy, stranger)
        XCTAssertEqual(note.repostedEventId, originalId)
    }

    func testTrustedRepostOfVerifiedNoteIsAdmitted() {
        let note = FeedNote(id: "r2", pubkey: trusted, content: forgedContent.replacingOccurrences(of: trusted, with: stranger),
                            createdAt: Date(), tags: [["e", originalId]], kind: 6, repostedBy: trusted, verify: { _ in true })
        XCTAssertEqual(note.pubkey, stranger)
        XCTAssertEqual(global([note]).count, 1, "a trusted reposter carries what they boost, as in Following")
    }
}
