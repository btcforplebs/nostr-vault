import XCTest
@testable import MediaLogic

/// The feed reads the open account's `wot_cache_<hex>.json`; the pooled
/// `wot_cache.json` only while that is missing (Android `WotFeedFilesTest`).
final class WotFeedFilesTests: XCTestCase {
    private let me = String(repeating: "a", count: 64)
    private let other = String(repeating: "b", count: 64)
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func write(_ name: String, _ json: String = #"{"pubkeys":{}}"#) throws {
        try Data(json.utf8).write(to: dir.appendingPathComponent(name))
    }

    func testTheOpenAccountsOwnFileWhenItExists() throws {
        try write("wot_cache.json")
        try write("wot_cache_\(me).json")
        let url = WotFiles.feedCacheURL(in: dir, owner: me)
        XCTAssertEqual(url.lastPathComponent, "wot_cache_\(me).json")
        XCTAssertTrue(WotFiles.isAccountCache(url))
        XCTAssertEqual(WotFiles.linksURL(beside: url).lastPathComponent, "wot_links_\(me).json")
        XCTAssertEqual(WotFiles.feedCacheURL(in: dir, owner: me.uppercased()).lastPathComponent, "wot_cache_\(me).json",
                       "upper-case hex finds the relay's lower-case file")
    }

    func testFallsBackToThePooledFileWhileTheAccountsIsMissing() throws {
        try write("wot_cache.json")
        try write("wot_cache_\(other).json")  // another account's file is never mine
        let url = WotFiles.feedCacheURL(in: dir, owner: me)
        XCTAssertEqual(url.lastPathComponent, "wot_cache.json")
        XCTAssertFalse(WotFiles.isAccountCache(url))
        XCTAssertEqual(WotFiles.linksURL(beside: url).lastPathComponent, "wot_links.json")
    }

    func testNoAccountOrABadKeyReadsThePooledFile() throws {
        try write("wot_cache_.json")
        XCTAssertEqual(WotFiles.feedCacheURL(in: dir, owner: "").lastPathComponent, "wot_cache.json")
        XCTAssertEqual(WotFiles.feedCacheURL(in: dir, owner: "../x").lastPathComponent, "wot_cache.json")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("wot_cache_\(me).json"),
                                                withIntermediateDirectories: true)
        XCTAssertEqual(WotFiles.feedCacheURL(in: dir, owner: me).lastPathComponent, "wot_cache.json",
                       "a folder named like the cache is not a cache")
    }

    func testTheAccountFileReadsAsThePooledShape() throws {
        // haven-go accountCache: version/depth/min_followers/follows/pubkeys/vouches/muted_follows.
        try write("wot_cache_\(me).json",
                  #"{"version":5,"depth":3,"min_followers":3,"timestamp":1,"follows":["\#(other)"],"pubkeys":{"\#(me)":true,"\#(other)":true},"vouches":{"\#(other)":4},"muted_follows":[]}"#)
        try write("wot_links_\(me).json", #"{"follows":["\#(other)"],"links":{"\#(other)":[0]}}"#)
        let url = WotFiles.feedCacheURL(in: dir, owner: me)
        let read = try XCTUnwrap(FeedFilterEngine.readWotCache(from: url, ownerHex: me))
        XCTAssertEqual(read.pubkeys, [me, other])
        XCTAssertEqual(read.depth, 3)
        XCTAssertEqual(read.vouches, [other: 4])
        XCTAssertNotNil(read.links, "the account's own links file is read beside its cache")
    }

    // MARK: Tron 2472 must-fix 1: an account switch re-reads

    func testAnAccountSwitchNeedsANewRead() throws {
        try write("wot_cache.json")
        try write("wot_cache_\(me).json")
        try write("wot_cache_\(other).json")
        let mine = WotFiles.feedCacheURL(in: dir, owner: me)
        let loaded = (path: mine.path, modified: WotFiles.stamp(cacheURL: mine))
        XCTAssertFalse(WotFiles.needsRead(loaded: loaded, cacheURL: mine), "same account, same file: no read")
        let theirs = WotFiles.feedCacheURL(in: dir, owner: other)
        XCTAssertTrue(WotFiles.needsRead(loaded: loaded, cacheURL: theirs),
                      "after a switch the other account's file is read, not the old web kept")
        XCTAssertTrue(WotFiles.needsRead(loaded: nil, cacheURL: mine))
    }

    func testBothAccountsOnThePooledFileKeepTheRead() throws {
        try write("wot_cache.json")
        let pooled = WotFiles.feedCacheURL(in: dir, owner: me)
        let loaded = (path: pooled.path, modified: WotFiles.stamp(cacheURL: pooled))
        XCTAssertFalse(WotFiles.needsRead(loaded: loaded, cacheURL: WotFiles.feedCacheURL(in: dir, owner: other)),
                       "the pooled web is every account's: nothing to re-read")
    }

    // MARK: Tron 2472 low 2: built at the account's level and bar

    private func writeBuilt(depth: Int, bar: Int) throws {
        try write("wot_cache_\(me).json",
                  #"{"version":5,"depth":\#(depth),"min_followers":\#(bar),"pubkeys":{"\#(me)":true}}"#)
    }

    func testTheAccountFileCountsAtItsOwnLevelAndBar() throws {
        try write("wot_cache.json")
        try writeBuilt(depth: 3, bar: 2)
        XCTAssertEqual(WotFiles.feedCacheURL(in: dir, owner: me, reach: AccountReach(depth: 3, minFollowers: 2)).lastPathComponent,
                       "wot_cache_\(me).json")
        XCTAssertEqual(WotFiles.feedCacheURL(in: dir, owner: me, reach: AccountReach(depth: 2, minFollowers: 2)).lastPathComponent,
                       "wot_cache.json", "another level: the relay gates from the pooled web until it rebuilds")
        XCTAssertEqual(WotFiles.feedCacheURL(in: dir, owner: me, reach: AccountReach(depth: 3, minFollowers: 5)).lastPathComponent,
                       "wot_cache.json", "another bar: pooled too")
    }

    func testTheLevelIsHeldToTheRelaysRange() throws {
        try write("wot_cache.json")
        try writeBuilt(depth: 1, bar: 0)
        XCTAssertTrue(WotFiles.builtAt(AccountReach(depth: 0, minFollowers: -1), cacheURL: dir.appendingPathComponent("wot_cache_\(me).json")),
                      "level 0 runs as 1 and a negative bar as 0 (haven-go reachOf)")
    }

    func testARebuildAtTheNewLevelIsSeen() throws {
        try write("wot_cache.json")
        try writeBuilt(depth: 2, bar: 3)
        let reach = AccountReach(depth: 3, minFollowers: 3)
        XCTAssertEqual(WotFiles.feedCacheURL(in: dir, owner: me, reach: reach).lastPathComponent, "wot_cache.json")
        // Same size, a later date: the memo must not keep the old answer.
        try writeBuilt(depth: 3, bar: 3)
        let url = dir.appendingPathComponent("wot_cache_\(me).json")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
        XCTAssertEqual(WotFiles.feedCacheURL(in: dir, owner: me, reach: reach).lastPathComponent, "wot_cache_\(me).json")
    }

    func testAnUnreadableAccountFileFallsBackToPooled() throws {
        try write("wot_cache.json")
        try write("wot_cache_\(me).json", "{not json")
        XCTAssertEqual(WotFiles.feedCacheURL(in: dir, owner: me, reach: AccountReach(depth: 3, minFollowers: 3)).lastPathComponent,
                       "wot_cache.json")
        XCTAssertEqual(WotFiles.feedCacheURL(in: dir, owner: me).lastPathComponent, "wot_cache_\(me).json",
                       "without a reach the file is only checked for being there")
    }
}
