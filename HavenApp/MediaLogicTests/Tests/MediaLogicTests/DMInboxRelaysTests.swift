import XCTest
@testable import MediaLogic

/// The DM inbox list: one list every device sends to and reads from, kept in
/// step across devices by "newest change wins".
final class DMInboxRelaysTests: XCTestCase {

    // MARK: - Merge

    func testHavenInboxComesFirstAndDuplicatesCollapse() {
        let merged = HavenConfig.mergedDMInboxRelays(
            havenInbox: "wss://vault.example.com/inbox",
            dmRelays: ["wss://relay.primal.net", "wss://vault.example.com/inbox/", "wss://Relay.Primal.net/"])
        XCTAssertEqual(merged, ["wss://vault.example.com/inbox", "wss://relay.primal.net"])
    }

    func testNoHavenInboxLeavesTheDMRelays() {
        let merged = HavenConfig.mergedDMInboxRelays(havenInbox: "", dmRelays: ["wss://nos.lol", " "])
        XCTAssertEqual(merged, ["wss://nos.lol"])
    }

    /// A Mac with a public address puts its own inbox first; a local-only one
    /// has nothing others can reach, so nothing is added. (The test package
    /// builds for macOS, so this exercises the macOS branch.)
    func testMacPublicAddressIsItsOwnHavenInbox() {
        var config = HavenConfig()
        config.relayURL = ""
        XCTAssertEqual(config.ownHavenDMInboxURL, "")
        config.relayURL = "https://vault.example.com/"
        XCTAssertEqual(config.ownHavenDMInboxURL, "wss://vault.example.com/inbox")
        XCTAssertEqual(config.dmInboxRelays.first, "wss://vault.example.com/inbox")
    }

    // MARK: - Sync across devices

    func testNothingPublishedMeansPublish() {
        XCTAssertEqual(HavenConfig.dmInboxSyncAction(local: ["wss://a"], localUpdatedAt: nil, published: nil, publishedAt: nil), .publish)
    }

    /// The bug: each device republished its own list at launch, so the last
    /// device opened won. A device that never edited its list must take the
    /// published one instead.
    func testDefaultsNeverOverwriteAPublishedList() {
        XCTAssertEqual(HavenConfig.dmInboxSyncAction(local: ["wss://defaults"], localUpdatedAt: nil,
                                                     published: ["wss://chosen"], publishedAt: 100), .adopt)
    }

    func testNewerPublishedListIsAdopted() {
        XCTAssertEqual(HavenConfig.dmInboxSyncAction(local: ["wss://old"], localUpdatedAt: 100,
                                                     published: ["wss://new"], publishedAt: 200), .adopt)
    }

    func testNewerLocalEditIsPublished() {
        XCTAssertEqual(HavenConfig.dmInboxSyncAction(local: ["wss://edited"], localUpdatedAt: 300,
                                                     published: ["wss://old"], publishedAt: 200), .publish)
    }

    func testSameListSameTimeDoesNothing() {
        XCTAssertEqual(HavenConfig.dmInboxSyncAction(local: ["wss://a/", "wss://B"], localUpdatedAt: 200,
                                                     published: ["wss://a", "wss://b"], publishedAt: 200), .none)
    }

    /// After adopting, a device that knows the Haven inbox (or dropped a
    /// loopback entry) holds a different list at the same timestamp, and
    /// must publish it so the others pick it up.
    func testAdoptedButDifferentIsPublished() {
        XCTAssertEqual(HavenConfig.dmInboxSyncAction(local: ["wss://vault/inbox", "wss://a"], localUpdatedAt: 200,
                                                     published: ["wss://a"], publishedAt: 200), .publish)
    }

    /// Older configs have no timestamp key; it must decode as nil, not fail.
    func testMissingTimestampDecodesAsNil() throws {
        let data = try JSONEncoder().encode(HavenConfig())
        var dict = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        dict.removeValue(forKey: "dmRelaysUpdatedAt")
        let stripped = try JSONSerialization.data(withJSONObject: dict)
        let decoded = try JSONDecoder().decode(HavenConfig.self, from: stripped)
        XCTAssertNil(decoded.dmRelaysUpdatedAt)
        var stamped = HavenConfig(); stamped.dmRelaysUpdatedAt = 42
        XCTAssertEqual(try JSONDecoder().decode(HavenConfig.self, from: JSONEncoder().encode(stamped)).dmRelaysUpdatedAt, 42)
    }
}
