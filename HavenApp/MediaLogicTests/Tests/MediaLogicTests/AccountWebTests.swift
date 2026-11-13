import XCTest
@testable import MediaLogic

/// The open account's own web out of the relay's pooled one (Logen 2026-11-13).
final class AccountWebTests: XCTestCase {
    // Two accounts on the device: `me` (open) and `alt`.
    // me follows f1 f2 f3; alt follows f1 g1 g2.
    // spam: followed by f1, g1, g2 -> 3 in the pool, only 1 of mine.
    // friend: followed by f1, f2, f3 -> 3 of mine.
    private let pooled: Set<String> = ["me", "alt", "f1", "f2", "f3", "g1", "g2", "spam", "friend"]
    private let links = TrustLinksIndex(
        follows: ["f1", "f2", "f3", "g1", "g2"],
        links: ["spam": [0, 3, 4], "friend": [0, 1, 2], "g1": [0], "f2": [3]])
    private let scope = AccountWebScope(owners: ["me", "alt"], minFollowers: 3, followsKnown: true)

    func testPooledFollowsOfAnotherAccountDoNotCount() {
        let web = AccountWeb.web(saved: pooled, follows: ["f1", "f2", "f3"], links: links, depth: 3, scope: scope)
        XCTAssertFalse(web.contains("spam"), "1 of my follows + 2 of alt's must not clear a bar of 3")
        XCTAssertFalse(web.contains("g1"), "alt's follows are not mine")
        XCTAssertTrue(web.contains("friend"))
        XCTAssertEqual(web, ["me", "alt", "f1", "f2", "f3", "friend"])
    }

    func testOtherAccountGetsItsOwnWeb() {
        let web = AccountWeb.web(saved: pooled, follows: ["f1", "g1", "g2"], links: links, depth: 3, scope: scope)
        XCTAssertTrue(web.contains("spam"), "for alt, spam has 3 follows")
        XCTAssertFalse(web.contains("friend"))
        XCTAssertFalse(web.contains("f2"))
    }

    func testLowerBarAndRepeatedIndexes() {
        var low = scope
        low.minFollowers = 2
        let dup = TrustLinksIndex(follows: links.follows, links: ["x": [0, 0, 0], "y": [0, 1]])
        let web = AccountWeb.web(saved: pooled.union(["x", "y"]), follows: ["f1", "f2"], links: dup, depth: 3, scope: low)
        XCTAssertFalse(web.contains("x"), "one follow listed three times is still one")
        XCTAssertTrue(web.contains("y"))
    }

    func testDepthTwoIsYouAndYourFollows() {
        let web = AccountWeb.web(saved: ["me", "alt", "f1", "g1"], follows: ["f1"], links: nil, depth: 2, scope: scope)
        XCTAssertEqual(web, ["me", "alt", "f1"])
    }

    func testFallsBackToTheSharedWebWhenItCannotTell() {
        let shared = TrustMap.web(saved: pooled, follows: ["f1"])
        // Follow list not loaded yet.
        var unknown = scope
        unknown.followsKnown = false
        XCTAssertEqual(AccountWeb.web(saved: pooled, follows: ["f1"], links: links, depth: 3, scope: unknown), shared)
        // No links file at depth 3 (older relay, unreadable file).
        XCTAssertEqual(AccountWeb.web(saved: pooled, follows: ["f1"], links: nil, depth: 3, scope: scope), shared)
        // No graph yet: just the follows, failing closed as before.
        XCTAssertEqual(AccountWeb.web(saved: [], follows: ["f1"], links: links, depth: 3, scope: scope), ["f1"])
        // Fewer follows than the bar: the relay widens a new account's web; keep its web.
        XCTAssertEqual(AccountWeb.web(saved: pooled, follows: ["f1", "f2"], links: links, depth: 3, scope: scope),
                       TrustMap.web(saved: pooled, follows: ["f1", "f2"]))
    }

    func testParsesTheRelayFile() {
        let data = Data(#"{"timestamp":1,"follows":["f1","f2"],"links":{"x":[0,1]}}"#.utf8)
        XCTAssertEqual(TrustLinksIndex.parse(data), TrustLinksIndex(follows: ["f1", "f2"], links: ["x": [0, 1]]))
        XCTAssertNil(TrustLinksIndex.parse(Data("nope".utf8)))
    }

    func testMemoUsesTheLoadedLinksAndRecomputesOnLoad() {
        let memo = TrustedWebMemo()
        memo.load(links: links, depth: 3)
        XCTAssertFalse(memo.web(saved: pooled, follows: ["f1", "f2", "f3"], scope: scope).contains("spam"))
        memo.load(links: nil, depth: 3)
        XCTAssertTrue(memo.web(saved: pooled, follows: ["f1", "f2", "f3"], scope: scope).contains("spam"))
        // No scope: the shared web, as before.
        memo.load(links: links, depth: 3)
        XCTAssertTrue(memo.web(saved: pooled, follows: ["f1", "f2", "f3"]).contains("spam"))
    }

    func testReadWotCacheReadsTheLinksBesideIt() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = dir.appendingPathComponent("wot_cache.json")
        try Data(#"{"depth":3,"pubkeys":{"me":true,"f1":true}}"#.utf8).write(to: cache)
        try Data(#"{"follows":["f1"],"links":{"x":[0]}}"#.utf8).write(to: dir.appendingPathComponent(TrustLinks.fileName))
        let read = try XCTUnwrap(FeedFilterEngine.readWotCache(from: cache, ownerHex: "me"))
        XCTAssertEqual(read.depth, 3)
        XCTAssertEqual(read.links, TrustLinksIndex(follows: ["f1"], links: ["x": [0]]))
    }
}
