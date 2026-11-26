import XCTest
@testable import MediaLogic

/// The reply hint never names this phone's own relay. Case from 2026-11-26:
/// a phone-only poster's `e` hint was `wss://127.0.0.1:3355`, so no other
/// client could find the parent. Android twin: ReplyRelayHintTest.
final class ReplyRelayHintTests: XCTestCase {
    func testPhoneOnlyPosterUsesFirstPublicWriteRelay() {
        var c = HavenConfig()
        c.relayURL = ""
        c.blastrRelays = ["wss://192.168.1.4:3355", "ws://nos.lol", "wss://relay.damus.io"]
        XCTAssertEqual(c.replyRelayHint, "wss://relay.damus.io")
    }

    func testReachableOwnDomainWins() {
        var c = HavenConfig()
        c.relayURL = "vault.example.com"
        c.blastrRelays = ["wss://relay.damus.io"]
        XCTAssertEqual(c.replyRelayHint, "wss://vault.example.com")
    }

    func testNoWriteRelaysUsesTheFallbackList() {
        var c = HavenConfig()
        c.relayURL = ""
        c.blastrRelays = []
        XCTAssertEqual(c.replyRelayHint, HavenConfig.fallbackWriteRelays.first)
    }

    func testNothingPublicGivesEmpty() {
        var c = HavenConfig()
        c.relayURL = ""
        c.blastrRelays = ["wss://localhost:4869", "wss://box.local"]
        XCTAssertEqual(c.replyRelayHint, "")
    }
}
