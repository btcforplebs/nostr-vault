import XCTest
@testable import MediaLogic

final class EmojiSetBrowseTests: XCTestCase {
    private let alice = String(repeating: "a", count: 64)
    private let bob = String(repeating: "b", count: 64)
    private let carol = String(repeating: "c", count: 64)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func set(_ id: String, by pk: String, d: String, at: Int64, emoji: Bool = true, kind: Int = 30030) -> EmojiSetBrowse.Candidate {
        var tags: [[String]] = [["d", d], ["title", "T-\(d)"]]
        if emoji { tags.append(["emoji", "wave", "https://e.example/\(id).png"]) }
        return .init(id: id, pubkey: pk, createdAt: at, kind: kind, tags: tags)
    }

    func testFiltersFollowsChunkedThenGlobalMonth() {
        let follows = (0..<1_001).map { String(format: "%064x", $0) } + ["not-hex", String(format: "%064x", 0)]
        let f = EmojiSetBrowse.filters(follows: follows, now: now)
        XCTAssertEqual(f.count, 4)
        XCTAssertEqual((f[0]["authors"] as? [String])?.count, 500)
        XCTAssertEqual((f[2]["authors"] as? [String])?.count, 1)
        XCTAssertEqual(f[0]["limit"] as? Int, 200)
        let global = f[3]
        XCTAssertNil(global["authors"])
        XCTAssertEqual(global["kinds"] as? [Int], [30030])
        XCTAssertEqual(global["limit"] as? Int, 200)
        XCTAssertEqual(global["since"] as? Int64, 1_800_000_000 - 30 * 86_400)
    }

    func testNoFollowsAsksGlobalOnly() {
        let f = EmojiSetBrowse.filters(follows: [], now: now)
        XCTAssertEqual(f.count, 1)
        XCTAssertNotNil(f[0]["since"])
    }

    func testListNewestPerSetFollowsFirstBlockedAndEmptyOut() {
        let events = [
            set("1", by: alice, d: "x", at: 100),
            set("2", by: alice, d: "x", at: 200),          // newer copy of the same set wins
            set("3", by: bob, d: "y", at: 900),            // stranger, newest
            set("4", by: carol, d: "z", at: 950),          // blocked
            set("5", by: bob, d: "e", at: 950, emoji: false), // no emoji
            set("6", by: bob, d: "k", at: 999, kind: 30031),  // not a set
            set("7", by: bob, d: "f", at: 1_800_000_000 + 3_600), // dated an hour ahead
        ]
        let out = EmojiSetBrowse.list(events, follows: [alice], blocked: [carol], now: now)
        XCTAssertEqual(out.map(\.set.address), ["30030:\(alice):x", "30030:\(bob):y"])
        XCTAssertEqual(out[0].createdAt, 200)
        XCTAssertTrue(out[0].byFollow)
        XCTAssertFalse(out[1].byFollow)
        XCTAssertEqual(out[0].set.emojis.first?.setAddress, "30030:\(alice):x")
        XCTAssertEqual(out[0].set.title, "T-x")
    }

    func testSameTimeTieKeepsLowerId() {
        let out = EmojiSetBrowse.list([set("b", by: alice, d: "x", at: 5), set("a", by: alice, d: "x", at: 5)],
                                      follows: [], blocked: [], now: now)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].set.emojis.first?.url, "https://e.example/a.png")
    }

    // MARK: Your old sets

    private func own(_ id: String, d: String, at: Int64, codes: Int, by pk: String? = nil) -> EmojiSetBrowse.Candidate {
        var tags: [[String]] = [["d", d]]
        for n in 0..<codes { tags.append(["emoji", "c\(n)", "https://e.example/\(d)/\(n).png"]) }
        return .init(id: id, pubkey: pk ?? alice, createdAt: at, kind: 30030, tags: tags)
    }

    func testOldSetsNotListedNewestWins() {
        let out = EmojiSetBrowse.oldSets([own("1", d: "x", at: 10, codes: 3), own("2", d: "x", at: 20, codes: 4),
                                          own("3", d: "y", at: 30, codes: 2), own("4", d: "z", at: 5, codes: 1, by: bob)],
                                         owner: alice, listed: ["30030:\(alice):y"], now: now)
        XCTAssertEqual(out.map(\.id), ["30030:\(alice):x"])     // y listed and intact, bob's not mine
        XCTAssertEqual(out[0].versionID, "2")
        XCTAssertFalse(out[0].needsRestore)
        XCTAssertEqual(out[0].found.set.emojis.count, 4)
    }

    func testOldSetsWipedStepsBackAndShowsEvenWhenListed() {
        let a = "30030:\(alice):x"
        let events = [own("1", d: "x", at: 10, codes: 12), own("2", d: "x", at: 20, codes: 12), own("3", d: "x", at: 30, codes: 0)]
        let out = EmojiSetBrowse.oldSets(events, owner: alice, listed: [a], now: now)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].versionID, "2")
        XCTAssertTrue(out[0].needsRestore)
        XCTAssertTrue(out[0].listed)
        // Halved from 12 to 5 is a wipe too; 12 to 7 is an edit.
        XCTAssertEqual(EmojiSetBrowse.oldSets([own("1", d: "x", at: 10, codes: 12), own("2", d: "x", at: 20, codes: 5)],
                                              owner: alice, listed: [], now: now).first?.versionID, "1")
        XCTAssertEqual(EmojiSetBrowse.oldSets([own("1", d: "x", at: 10, codes: 12), own("2", d: "x", at: 20, codes: 7)],
                                              owner: alice, listed: [a], now: now).count, 0)
    }

    func testOldSetsOnlyEmptyVersionsShowNothing() {
        XCTAssertTrue(EmojiSetBrowse.oldSets([own("1", d: "x", at: 10, codes: 0)], owner: alice, listed: [], now: now).isEmpty)
    }

    func testEmojiSetIsAProtectedList() {
        XCTAssertTrue(ListShrinkRule.isProtected(30030))
        XCTAssertEqual(ListShrinkRule.name(30030), "emoji set")
        let v = ListVersion(id: "a", pubkey: alice, kind: 30030, createdAt: 1, tags: [["d", "x"]], content: "")
        XCTAssertEqual(v.d, "x")
    }
}
