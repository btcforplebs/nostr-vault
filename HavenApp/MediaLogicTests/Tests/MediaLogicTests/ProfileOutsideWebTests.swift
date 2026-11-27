import XCTest
@testable import MediaLogic

/// The profile page on the one gate (audit RESEARCH/NV_PROFILE_OUTSIDE_WEB_AUDIT_APPLE.md,
/// Logen 11-27): what the Tagged, Reposts and Replies tabs show, and the
/// counts under each row.
final class ProfileOutsideWebTests: XCTestCase {
    private let owner = String(repeating: "a", count: 64)
    private let me = String(repeating: "0", count: 64)
    private let follow = String(repeating: "1", count: 64)
    private let stranger = String(repeating: "4", count: 64)
    private let blocked = String(repeating: "9", count: 64)

    private func gate(blocked extra: Set<String> = [], mutes: MuteList = .empty) -> WebGate.Web {
        WebGate.Web(own: [me], web: [follow, owner], blocked: Set([blocked]).union(extra), mutes: mutes)
    }

    private func note(_ id: String, by author: String, content: String = "gm", tags: [[String]] = [],
                      kind: Int = 1, repostedBy: String? = nil, at offset: TimeInterval = 0) -> FeedNote {
        FeedNote(id: id, pubkey: author, content: content, createdAt: Date(timeIntervalSince1970: 1_800_000_000 + offset),
                 tags: tags, kind: kind, repostedBy: repostedBy)
    }

    private func bucket(_ notes: [FeedNote] = [], tagged: [FeedNote] = [], gate g: WebGate.Web? = nil,
                        authorOf: @escaping (String) -> String? = { _ in nil }) -> ProfileNoteBuckets {
        ProfileBucketing.buckets(notes: notes, tagged: tagged, owner: owner, gate: g ?? gate(), authorOf: authorOf)
    }

    // MARK: 1. Tagged

    func testTaggedKeepsInsideFoldsOutsideAndDropsBlocked() {
        let p = [["p", owner]]
        let b = bucket(tagged: [note("f", by: follow, tags: p), note("s", by: stranger, tags: p),
                                note("b", by: blocked, tags: p), note("m", by: me, tags: p)])
        XCTAssertEqual(b.tagged.map(\.id), ["f", "m"])
        XCTAssertEqual(b.taggedOutside.map(\.id), ["s"])
    }

    func testTaggedDropsMutedWords() {
        let mutes = MuteList(publicTags: [["word", "airdrop"]])
        let b = bucket(tagged: [note("w", by: follow, content: "free airdrop", tags: [["p", owner]])],
                       gate: gate(mutes: mutes))
        XCTAssertTrue(b.tagged.isEmpty)
        XCTAssertTrue(b.taggedOutside.isEmpty)
    }

    // MARK: 2. Reposts

    func testAStrangersRepostOfTheOwnersPostIsNotTheirRepost() {
        // Embedded kind 6: pubkey is the original author, repostedBy the reposter.
        let theirs = note("r1", by: owner, kind: 6, repostedBy: stranger)
        let own = note("r2", by: follow, kind: 6, repostedBy: owner)
        XCTAssertEqual(bucket([theirs, own]).reposts.map(\.id), ["r2"])
    }

    // MARK: 6. Blocks and mutes on reposts and replies

    func testRepostOfABlockedPersonGoes() {
        let r = note("r", by: blocked, kind: 6, repostedBy: owner)
        XCTAssertTrue(bucket([r]).reposts.isEmpty)
    }

    func testReplyToABlockedPersonGoesWithItsMedia() {
        let reply = note("re", by: owner, content: "look https://x.com/a.jpg",
                         tags: [["e", "parent", "", "reply"], ["p", blocked]])
        let b = bucket([reply], authorOf: { $0 == "parent" ? self.blocked : nil })
        XCTAssertTrue(b.replies.isEmpty)
        XCTAssertTrue(b.media.isEmpty)
    }

    func testABlockedPersonsOwnProfileStillShowsTheirRows() {
        let g = gate(blocked: [owner])
        let reply = note("re", by: owner, tags: [["e", "parent", "", "reply"]])
        let top = note("t", by: owner)
        let b = bucket([reply, top], gate: g, authorOf: { $0 == "parent" ? self.follow : nil })
        XCTAssertEqual(b.replies.map(\.id), ["re"])
        XCTAssertEqual(b.top.map(\.id), ["t"])
    }

    // MARK: 3. Row counts

    func testCountsLeaveOutPeopleOutsideYourWeb() {
        let events: [[String: Any]] = [
            ["id": "l1" + String(repeating: "0", count: 62), "kind": 7, "pubkey": follow, "content": "+", "tags": [["e", "post"]]],
            ["id": "l2" + String(repeating: "0", count: 62), "kind": 7, "pubkey": stranger, "content": "+", "tags": [["e", "post"]]],
            ["id": "r1" + String(repeating: "0", count: 62), "kind": 6, "pubkey": stranger, "content": "", "tags": [["e", "post"]]],
            ["id": "c1" + String(repeating: "0", count: 62), "kind": 1, "pubkey": follow, "content": "yes",
             "tags": [["e", "post", "", "reply"]]],
            ["id": "c2" + String(repeating: "0", count: 62), "kind": 1, "pubkey": stranger, "content": "spam",
             "tags": [["e", "post", "", "reply"]]],
            ["id": "q1" + String(repeating: "0", count: 62), "kind": 1, "pubkey": blocked, "content": "lol",
             "tags": [["q", "post"]]],
        ]
        let ledger = PostEngagementQuery.contributions(events, targets: ["post"])["post"]!
        let inside = GateInsideKeys.build(gate(), isPublic: { _ in false })
        let e = ledger.engagement(isInside: { inside.contains($0) })
        XCTAssertEqual(e.likes, 1)
        XCTAssertEqual(e.reposts, 0)
        XCTAssertEqual(e.replies, 1)
        XCTAssertEqual(e.quotes, 0)
        // Everything is still in the ledger; only the shown counts change.
        XCTAssertEqual(ledger.engagement.likes, 2)
        XCTAssertEqual(ledger.engagement.replies, 2)
    }

    func testAReplyWithNoRecordedAuthorIsNotCounted() {
        var ledger = EngagementLedger()
        ledger.replies = ["c1"]
        ledger.responders = nil
        XCTAssertEqual(ledger.engagement(isInside: { _ in true }).replies, 0)
    }

    func testOldLedgersWithoutRespondersStillDecode() throws {
        let json = #"{"likers":[],"reposters":[],"replies":["c1"],"quotes":[],"zaps":{},"isLowerBound":true}"#
        let ledger = try JSONDecoder().decode(EngagementLedger.self, from: Data(json.utf8))
        XCTAssertNil(ledger.responders)
    }

    func testInsideKeysLeaveOutBlockedAndPublicKeys() {
        let g = WebGate.Web(own: [me], web: [follow, stranger, blocked], blocked: [blocked])
        let keys = GateInsideKeys.build(g, isPublic: { $0 == self.stranger })
        XCTAssertEqual(keys, [EngagementLedger.key(me), EngagementLedger.key(follow)])
    }

    // MARK: 4/5. Followers

    func testFollowerInsideIsTheGatesRule() {
        let g = gate()
        XCTAssertTrue(WebGate.isInside(follow, in: g))
        XCTAssertTrue(WebGate.isInside(me, in: g))
        XCTAssertFalse(WebGate.isInside(stranger, in: g))
        XCTAssertFalse(WebGate.isInside(blocked, in: g))
    }
}
