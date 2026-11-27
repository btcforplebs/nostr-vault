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

/// A reaction's `e` hint is the same public hint a reply uses, not the
/// phone's own relay (FeedActions.react; Tod 2026-11-27).
final class ReactionRelayHintTests: XCTestCase {
    func testFeedReactionsUseTheReplyHint() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("HavenApp/Views/FeedActions.swift")
        let src = try String(contentsOf: file, encoding: .utf8)
        let react = try XCTUnwrap(src.range(of: "private static func react(to note: FeedNote"))
        let body = src[react.upperBound...].prefix(2500)
        XCTAssertTrue(body.contains("let relayHint = ConfigService.shared.config.replyRelayHint"))
        XCTAssertFalse(body.contains("config.nostrURL"), "the kind 7 hint must not be this phone's relay")
    }
}
