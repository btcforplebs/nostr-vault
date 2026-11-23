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
}
