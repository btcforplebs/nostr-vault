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
}
