import XCTest
@testable import MediaLogic

/// The owner's own relay list (kind 10002) is the read and write relays: the
/// starter relays are only for an account with no list, and an edit made here
/// is kept until a newer list is published (Logen 2026-11-01).
final class OwnRelayListTests: XCTestCase {

    private let theirRead = ["wss://read.example.com", "wss://both.example.com"]
    private let theirWrite = ["wss://write.example.com", "wss://both.example.com"]

    // MARK: - Adopting

    func testAFreshInstallTakesTheirListOverTheStarters() {
        var config = HavenConfig()
        XCTAssertNil(config.relayListUpdatedAt)
        XCTAssertTrue(config.adoptRelayList(read: theirRead, write: theirWrite, publishedAt: 1_000))
        XCTAssertEqual(config.feedRelays, theirRead)
        XCTAssertEqual(config.blastrRelays, theirWrite)
        XCTAssertEqual(config.relayListUpdatedAt, 1_000)
        XCTAssertFalse(config.readRelays.contains("wss://relay.snort.social"))
        XCTAssertFalse(config.writeRelays.contains("wss://relay.snort.social"))
    }

    func testANewerListReplacesAnAdoptedOne() {
        var config = HavenConfig()
        config.adoptRelayList(read: theirRead, write: theirWrite, publishedAt: 1_000)
        XCTAssertTrue(config.adoptRelayList(read: ["wss://new.example.com"], write: ["wss://new.example.com"], publishedAt: 2_000))
        XCTAssertEqual(config.feedRelays, ["wss://new.example.com"])
        XCTAssertEqual(config.relayListUpdatedAt, 2_000)
    }

    func testAnOlderOrSameListChangesNothing() {
        var config = HavenConfig()
        config.adoptRelayList(read: theirRead, write: theirWrite, publishedAt: 2_000)
        XCTAssertFalse(config.adoptRelayList(read: ["wss://old.example.com"], write: ["wss://old.example.com"], publishedAt: 1_000))
        XCTAssertFalse(config.adoptRelayList(read: ["wss://old.example.com"], write: ["wss://old.example.com"], publishedAt: 2_000))
        XCTAssertEqual(config.feedRelays, theirRead)
        XCTAssertEqual(config.relayListUpdatedAt, 2_000)
    }

    func testAnEditHereIsKeptOverAnOlderPublishedList() {
        var config = HavenConfig()
        config.feedRelays = ["wss://mine.example.com"]
        config.blastrRelays = ["wss://mine.example.com"]
        config.relayListUpdatedAt = 5_000
        XCTAssertFalse(config.adoptRelayList(read: theirRead, write: theirWrite, publishedAt: 4_000))
        XCTAssertEqual(config.feedRelays, ["wss://mine.example.com"])
        // A list published after the edit (in another app) wins.
        XCTAssertTrue(config.adoptRelayList(read: theirRead, write: theirWrite, publishedAt: 6_000))
        XCTAssertEqual(config.feedRelays, theirRead)
    }

    func testUnusableBlockedAndDeadRelaysAreLeftOut() {
        var config = HavenConfig()
        config.blockedRelays = ["wss://blocked.example.com"]
        config.adoptRelayList(
            read: ["wss://read.example.com/", "wss://127.0.0.1:3355", "ws://plain.example.com", "wss://nos.lol",
                   "wss://blocked.example.com", "wss://READ.example.com"],
            write: ["wss://write.example.com"], publishedAt: 1_000)
        XCTAssertEqual(config.feedRelays, ["wss://read.example.com"])
        XCTAssertEqual(config.blastrRelays, ["wss://write.example.com"])
    }

    /// A list with only write relays leaves reading where it was (and the
    /// reverse), rather than leaving that side empty.
    func testAnEmptySideKeepsWhatItHad() {
        var config = HavenConfig()
        let starters = config.feedRelays
        XCTAssertTrue(config.adoptRelayList(read: [], write: ["wss://write.example.com"], publishedAt: 1_000))
        XCTAssertEqual(config.feedRelays, starters)
        XCTAssertEqual(config.blastrRelays, ["wss://write.example.com"])
    }

    // MARK: - Existing installs (no stamp saved yet)

    private func decodedWithoutStamp(read: [String], write: [String]) throws -> HavenConfig {
        var config = HavenConfig()
        config.feedRelays = read
        config.blastrRelays = write
        let data = try JSONEncoder().encode(config)
        var dict = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        dict.removeValue(forKey: "relayListUpdatedAt")
        return try JSONDecoder().decode(HavenConfig.self, from: JSONSerialization.data(withJSONObject: dict))
    }

    func testAnInstallStillOnShippedRelaysAdoptsTheirList() throws {
        // Today's starters, and an older default set with dead relays.
        for (read, write) in [(HavenConfig.starterRelays, HavenConfig.starterRelays),
                              (["wss://nos.lol", "wss://relay.primal.net", "wss://nostr.mom"],
                               ["wss://relay.btcforplebs.com", "wss://relay.damus.io", "wss://relay.snort.social"])] {
            var config = try decodedWithoutStamp(read: read, write: write)
            XCTAssertNil(config.relayListUpdatedAt, "\(read)")
            XCTAssertTrue(config.adoptRelayList(read: theirRead, write: theirWrite, publishedAt: 1_000))
            XCTAssertEqual(config.feedRelays, theirRead)
        }
    }

    func testAnInstallWithItsOwnRelaysKeepsThem() throws {
        let mine = HavenConfig.starterRelays + ["wss://mine.example.com"]
        var config = try decodedWithoutStamp(read: mine, write: HavenConfig.starterRelays)
        XCTAssertNotNil(config.relayListUpdatedAt)
        XCTAssertFalse(config.adoptRelayList(read: theirRead, write: theirWrite, publishedAt: 1_000))
        XCTAssertEqual(config.feedRelays, mine)
    }

    /// The Mac relay or this device's own relay in a list is not an edit.
    func testUnreachableEntriesDontCountAsAnEdit() {
        XCTAssertTrue(HavenConfig.relayListsLookUnedited(
            read: HavenConfig.starterRelays + ["ws://192.168.1.20:3355", "wss://127.0.0.1:3355"],
            write: HavenConfig.starterRelays))
        XCTAssertFalse(HavenConfig.relayListsLookUnedited(read: ["wss://mine.example.com"], write: []))
    }

    func testTheStampRoundTrips() throws {
        var config = HavenConfig(); config.relayListUpdatedAt = 42
        XCTAssertEqual(try JSONDecoder().decode(HavenConfig.self, from: JSONEncoder().encode(config)).relayListUpdatedAt, 42)
    }
}
