import XCTest
@testable import MediaLogic

/// Compact view is gone (Logen, 2026-11-11): a config saved with it loads
/// expanded with replies off, and never fails to load.
final class FeedLayoutConfigMigrationTests: XCTestCase {
    private func load(layouts: [String: String]?, compact: [String: Bool]?, replies: Bool) throws -> HavenConfig {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(HavenConfig.default)) as? [String: Any])
        json["feedLayoutModes"] = layouts
        json["feedCompactModes"] = compact
        json["showReplies"] = replies
        return try JSONDecoder().decode(HavenConfig.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testSavedCondensedLoadsExpandedWithRepliesOff() throws {
        let config = try load(layouts: ["Global": "condensed", "Following": "threaded"], compact: [:], replies: true)
        XCTAssertEqual(config.feedLayoutModes["Global"], "expanded")
        XCTAssertEqual(config.feedLayoutModes["Following"], "threaded")
        XCTAssertFalse(config.showReplies)
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
