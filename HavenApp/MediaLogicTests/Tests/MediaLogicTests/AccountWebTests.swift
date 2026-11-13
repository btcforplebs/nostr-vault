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
    }

    // Tron 2011 must-fix 1: the relay only widens when the *pooled* follows
    // are under the bar, so an open account with few follows must not get the
    // other account's whole web.
    func testFewFollowsWidenFromTheOpenAccountsFollowsOnly() {
        // me follows f1 and f2; alt's follows (g1 g2) are not mine.
        let web = AccountWeb.web(saved: pooled, follows: ["f1", "f2"], links: links, depth: 3, scope: scope)
        XCTAssertEqual(web, ["me", "alt", "f1", "f2", "spam", "friend", "g1"],
                       "anyone one of my own follows follows; f2 is mine already")
        XCTAssertFalse(web.contains("g2"), "only alt's follows follow g2")
        // No follows at all: you and your accounts, nothing pooled.
        XCTAssertEqual(AccountWeb.web(saved: pooled, follows: [], links: links, depth: 3, scope: scope), ["me", "alt"])
        // Tron's probe: me follows nobody, alt follows g1 g2 g3, all three follow spam.
        let probe = TrustLinksIndex(follows: ["g1", "g2", "g3"], links: ["spam": [0, 1, 2]])
        XCTAssertEqual(AccountWeb.web(saved: ["me", "alt", "g1", "g2", "g3", "spam"], follows: [], links: probe,
                                      depth: 3, scope: scope), ["me", "alt"])
    }

    func testWideningKeepsTheMostFollowedUnderTheCap() {
        var bigLinks: [String: [Int]] = [:]
        for n in 0..<(AccountWeb.newAccountWebCap + 5) { bigLinks[String(format: "p%05d", n)] = [0] }
        bigLinks["top"] = [0, 1]
        let big = TrustLinksIndex(follows: ["f1", "f2"], links: bigLinks)
        let web = AccountWeb.web(saved: Set(bigLinks.keys).union(["me"]), follows: ["f1", "f2"], links: big,
                                 depth: 3, scope: scope)
        XCTAssertEqual(web.count, 4 + AccountWeb.newAccountWebCap, "me, alt, f1, f2 plus the cap")
        XCTAssertTrue(web.contains("top"), "followed by both of my follows: first in")
        XCTAssertTrue(web.contains("p00000"))
        XCTAssertFalse(web.contains("p01004"), "ties go by key, the tail is cut")
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

    // Tron 2011 must-fix 2: the relay renames the cache, then writes the
    // links. A change to either file must count as a change.
    func testWotFilesStampAndLinksCurrent() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = dir.appendingPathComponent("wot_cache.json")
        let linksURL = WotFiles.linksURL(beside: cache)
        func touch(_ url: URL, _ seconds: TimeInterval) throws {
            if !FileManager.default.fileExists(atPath: url.path) { try Data(#"{"pubkeys":{"me":true}}"#.utf8).write(to: url) }
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: seconds)],
                                                  ofItemAtPath: url.path)
        }
        XCTAssertNil(WotFiles.stamp(cacheURL: cache))
        // First depth-3 build, read between the writes: no links yet.
        try touch(cache, 1_000)
        XCTAssertEqual(WotFiles.stamp(cacheURL: cache), Date(timeIntervalSince1970: 1_000))
        XCTAssertFalse(WotFiles.linksCurrent(cacheURL: cache, depth: 3))
        XCTAssertTrue(WotFiles.linksCurrent(cacheURL: cache, depth: 2), "depth 2 has no links to wait for")
        // The links land: the stamp moves, so a reload keyed to it happens.
        try touch(linksURL, 1_001)
        XCTAssertEqual(WotFiles.stamp(cacheURL: cache), Date(timeIntervalSince1970: 1_001))
        XCTAssertTrue(WotFiles.linksCurrent(cacheURL: cache, depth: 3))
        // A rebuild after a follow: new cache, last build's links.
        try touch(cache, 2_000)
        XCTAssertFalse(WotFiles.linksCurrent(cacheURL: cache, depth: 3))
        let read = try XCTUnwrap(FeedFilterEngine.readWotCache(from: cache, ownerHex: "me"))
        XCTAssertTrue(read.linksCurrent, "no depth: an older relay, nothing to wait for")
        try Data(#"{"depth":3,"pubkeys":{"me":true,"f1":true}}"#.utf8).write(to: cache)
        try touch(cache, 2_000)
        XCTAssertFalse(try XCTUnwrap(FeedFilterEngine.readWotCache(from: cache, ownerHex: "me")).linksCurrent)
        try touch(linksURL, 2_001)
        XCTAssertEqual(WotFiles.stamp(cacheURL: cache), Date(timeIntervalSince1970: 2_001))
        XCTAssertTrue(try XCTUnwrap(FeedFilterEngine.readWotCache(from: cache, ownerHex: "me")).linksCurrent)
    }

    // Tron 2011 low 4: a main-thread read skips the links file.
    func testReadWotCacheCanSkipTheLinks() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = dir.appendingPathComponent("wot_cache.json")
        try Data(#"{"depth":3,"pubkeys":{"me":true,"f1":true}}"#.utf8).write(to: cache)
        try Data(#"{"follows":["f1"],"links":{"x":[0]}}"#.utf8).write(to: dir.appendingPathComponent(TrustLinks.fileName))
        let read = try XCTUnwrap(FeedFilterEngine.readWotCache(from: cache, ownerHex: "me", readLinks: false))
        XCTAssertNil(read.links)
        XCTAssertEqual(read.depth, 3)
        XCTAssertEqual(read.pubkeys, ["me", "f1"])
    }

    func testMemoKeepsItsLinksOnADepthOnlyLoad() {
        let memo = TrustedWebMemo()
        memo.load(links: links, depth: 3)
        XCTAssertFalse(memo.web(saved: pooled, follows: ["f1", "f2", "f3"], scope: scope).contains("spam"))
        memo.load(depth: 3)
        XCTAssertFalse(memo.web(saved: pooled, follows: ["f1", "f2", "f3"], scope: scope).contains("spam"),
                       "a graph read without links keeps the last links")
        memo.load(links: nil)
        XCTAssertTrue(memo.web(saved: pooled, follows: ["f1", "f2", "f3"], scope: scope).contains("spam"))
    }

    /// The FeedService wiring Tron flagged (2011 must-fix 2, should-fix 3, low 4).
    func testFeedServiceWiring() throws {
        let app = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("HavenApp")
        func src(_ path: String) throws -> String {
            try String(contentsOf: app.appendingPathComponent(path), encoding: .utf8)
        }
        let wot = try src("Services/Feed/FeedService+WebOfTrust.swift")
        XCTAssertFalse(wot.contains("modificationDate(of: cacheURL)"), "every reload key covers both files")
        XCTAssertTrue(wot.contains("WotFiles.stamp(cacheURL: cacheURL)"))
        XCTAssertTrue(wot.contains("readLinks: false"), "the main-thread read skips the links")
        XCTAssertTrue(wot.contains("followListIsKnown || (hasAttemptedContactLoad && !followedPubkeys.isEmpty)"))
        let haze = try src("Views/TrustWeb/TrustWebView+FacesAndFilters.swift")
        XCTAssertFalse(haze.contains("FeedService.shared.feedTrustedPubkeys"), "the globe builds its web off the main thread")
    }
}
