import XCTest
@testable import MediaLogic

/// Search must never show someone you blocked, and must keep showing
/// everyone else (the unblocked control in each test).
final class SearchBlockFilterTests: XCTestCase {
    private struct Person { let pubkey: String }
    private struct Note { let pubkey: String; let repostedBy: String? }

    private let filter = SearchBlockFilter(blocked: ["blocked"])

    func testProfilesDropBlockedKeepOthers() {
        let out = filter.profiles([Person(pubkey: "blocked"), Person(pubkey: "friend")], pubkey: \.pubkey)
        XCTAssertEqual(out.map(\.pubkey), ["friend"])
    }

    func testSuggestedPubkeysDropBlockedKeepOrder() {
        XCTAssertEqual(filter.pubkeys(["a", "blocked", "b"]), ["a", "b"])
    }

    func testNotesUseTheGivenCheckIncludingReposts() {
        let notes = [
            Note(pubkey: "blocked", repostedBy: nil),
            Note(pubkey: "friend", repostedBy: "blocked"),
            Note(pubkey: "friend", repostedBy: nil),
        ]
        let out = filter.notes(notes) { note, blocked in
            blocked.contains(note.pubkey) || note.repostedBy.map(blocked.contains) == true
        }
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.pubkey, "friend")
        XCTAssertNil(out.first?.repostedBy)
    }

    func testNoBlocksPassesEverythingThrough() {
        let open = SearchBlockFilter(blocked: [])
        XCTAssertEqual(open.pubkeys(["a", "b"]), ["a", "b"])
        XCTAssertEqual(open.notes([Note(pubkey: "a", repostedBy: nil)]) { _, _ in true }.count, 1)
    }
}
