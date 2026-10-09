import XCTest
@testable import MediaLogic

/// The read and write relay roles every feature asks for, instead of each one
/// building its own "configured list, or primal + nos.lol" fallback.
final class RelayRolesTests: XCTestCase {

    func testReadRelaysAreTheFeedRelays() {
        var config = HavenConfig()
        config.feedRelays = ["wss://a.example", "wss://b.example"]
        config.blastrRelays = ["wss://w.example"]
        XCTAssertEqual(config.readRelays, ["wss://a.example", "wss://b.example"])
    }

    func testWriteRelaysAreTheBroadcastRelays() {
        var config = HavenConfig()
        config.feedRelays = ["wss://a.example"]
        config.blastrRelays = ["wss://w.example"]
        XCTAssertEqual(config.writeRelays, ["wss://w.example"])
    }

    func testEmptyRolesFallBack() {
        var config = HavenConfig()
        config.feedRelays = []
        config.blastrRelays = []
        XCTAssertEqual(config.readRelays, HavenConfig.fallbackRelays)
        XCTAssertEqual(config.writeRelays, HavenConfig.fallbackWriteRelays)
        XCTAssertFalse(HavenConfig.fallbackRelays.isEmpty)
        XCTAssertFalse(HavenConfig.fallbackWriteRelays.isEmpty)
    }

    /// The Mac relay is part of both roles, so an owner with only a Mac relay
    /// reads and writes there rather than on the fallback relays.
    func testMacRelayLeadsBothRoles() {
        var config = HavenConfig()
        config.macRelayURL = "https://mac.example.com"
        config.feedRelays = []
        config.blastrRelays = ["wss://w.example"]
        XCTAssertEqual(config.readRelays, ["wss://mac.example.com"])
        XCTAssertEqual(config.writeRelays, ["wss://mac.example.com", "wss://w.example"])
    }

    /// Writes fall back to the default broadcast list, not the read fallback.
    func testBroadcastFallbackIsTheWriteFallback() {
        XCTAssertEqual(RelayConfiguration.fallbackBroadcastRelays, HavenConfig.fallbackWriteRelays)
        XCTAssertEqual(HavenConfig.fallbackWriteRelays, HavenConfig().blastrRelays)
    }

    // MARK: - Public relay list (kind 10002)

    func testBothListsHaveNoMarkerOneListIsMarked() {
        let tags = HavenConfig.publicRelayListTags(
            ownRelays: [],
            read: ["wss://both.example", "wss://r.example"],
            write: ["wss://both.example/", "wss://w.example"])
        XCTAssertEqual(tags, [
            ["r", "wss://both.example"],
            ["r", "wss://r.example", "read"],
            ["r", "wss://w.example", "write"],
        ])
    }

    /// The owner's own relay comes first with no marker, so it is always in
    /// Write, even when it is also in only one of the lists.
    func testOwnRelayLeadsUnmarked() {
        let tags = HavenConfig.publicRelayListTags(
            ownRelays: ["wss://vault.example.com", ""],
            read: ["wss://vault.example.com"],
            write: ["wss://w.example"])
        XCTAssertEqual(tags, [["r", "wss://vault.example.com"], ["r", "wss://w.example", "write"]])
    }

    func testUnreachableRelaysAreLeftOut() {
        let tags = HavenConfig.publicRelayListTags(
            ownRelays: ["wss://192.168.1.20:3355"],
            read: ["ws://127.0.0.1:3355", "wss://mac.local", "https://x.example", "wss://ok.example"],
            write: [])
        XCTAssertEqual(tags, [["r", "wss://ok.example", "read"]])
    }

    func testConfigListsTheDomainMacAndRoles() {
        var config = HavenConfig()
        config.relayURL = "https://vault.example.com/"
        config.macRelayURL = ""
        config.feedRelays = ["wss://r.example"]
        config.blastrRelays = ["wss://w.example"]
        XCTAssertEqual(config.publicRelayListTags, [
            ["r", "wss://vault.example.com"],
            ["r", "wss://r.example", "read"],
            ["r", "wss://w.example", "write"],
        ])
    }

    /// A device-only relay is not advertised, but the Read and Write relays are.
    func testLocalRelayStillListsTheRoles() {
        var config = HavenConfig()
        config.relayURL = ""
        config.macRelayURL = ""
        config.feedRelays = ["wss://r.example"]
        config.blastrRelays = ["wss://r.example"]
        XCTAssertEqual(config.publicRelayListTags, [["r", "wss://r.example"]])
    }
}
