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
}
