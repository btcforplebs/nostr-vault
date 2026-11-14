import XCTest
@testable import MediaLogic

/// Compact view is gone (Logen, 2026-11-11): a config saved with it loads
/// expanded with replies off, and never fails to load.
final class FeedLayoutConfigMigrationTests: XCTestCase {
    private func load(layouts: [String: String]?, compact: [String: Bool]?, replies: Bool, repliesBackOnDone: Bool? = true) throws -> HavenConfig {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(HavenConfig.default)) as? [String: Any])
        json["feedLayoutModes"] = layouts
        json["feedCompactModes"] = compact
        json["showReplies"] = replies
        json["repliesBackOnV1"] = repliesBackOnDone
        return try JSONDecoder().decode(HavenConfig.self, from: JSONSerialization.data(withJSONObject: json))
    }

    /// A "condensed" layout (left by a copied settings file, 11/14) is
    /// rewritten as expanded and leaves replies alone: turning them off on
    /// every load kept switching Logen's Replies off.
    func testSavedCondensedLoadsExpandedAndKeepsReplies() throws {
        let config = try load(layouts: ["Global": "condensed", "Following": "threaded"], compact: [:], replies: true)
        XCTAssertEqual(config.feedLayoutModes["Global"], "expanded")
        XCTAssertEqual(config.feedLayoutModes["Following"], "threaded")
        XCTAssertTrue(config.showReplies)
    }

    /// Once: the loop above left replies off, so a config without the
    /// flag turns them back on and sets it.
    func testRepliesTurnBackOnOnce() throws {
        let config = try load(layouts: ["Global": "threaded"], compact: nil, replies: false, repliesBackOnDone: nil)
        XCTAssertTrue(config.showReplies)
        XCTAssertTrue(config.repliesBackOnV1)
        let again = try JSONDecoder().decode(HavenConfig.self, from: JSONEncoder().encode({ var c = config; c.showReplies = false; return c }()))
        XCTAssertFalse(again.showReplies)
    }

    func testLegacyCompactStillWinsOverTheOneTimeReset() throws {
        let config = try load(layouts: nil, compact: ["Discovery": true], replies: true, repliesBackOnDone: nil)
        XCTAssertFalse(config.showReplies)
        XCTAssertTrue(config.repliesBackOnV1)
    }

    func testLegacyCompactSwitchLoadsExpandedWithRepliesOff() throws {
        let config = try load(layouts: nil, compact: ["Discovery": true], replies: true)
        XCTAssertEqual(config.feedLayoutModes["Discovery"], "expanded")
        XCTAssertFalse(config.showReplies)
    }

    func testNoCompactKeepsReplies() throws {
        let config = try load(layouts: ["Global": "threaded"], compact: ["Global": true], replies: true)
        XCTAssertEqual(config.feedLayoutModes["Global"], "threaded")
        XCTAssertTrue(config.showReplies)
    }

    func testNewInstallOpensThreadedWithReplies() {
        XCTAssertTrue(HavenConfig.default.showReplies)
        XCTAssertFalse(HavenConfig.default.feedLayoutModes.values.contains("condensed"))
    }
}
