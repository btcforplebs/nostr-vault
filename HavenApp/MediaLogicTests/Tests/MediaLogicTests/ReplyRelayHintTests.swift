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

/// No event this app signs names this phone's own relay (`nostrURL`, often
/// 127.0.0.1) as the hint for the note it points at: article likes and
/// highlights, poll votes and reposts use the reply hint too (Tod 2026-11-27).
final class WriteHintNotLoopbackTests: XCTestCase {
    private var app: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("HavenApp")
    }

    /// Every app source line that sets a hint for a signed event from `nostrURL`.
    private func loopbackHintLines() throws -> [String] {
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil))
        var found: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            for (i, line) in lines.enumerated() {
                let hint = line.contains("relayHint") || (i > 0 && lines[i - 1].contains("relayHint"))
                    // ArticleReaderView's highlight named it `relay` first.
                    || line.trimmingCharacters(in: .whitespaces) == "let relay = ConfigService.shared.config.nostrURL"
                if hint && line.contains("config.nostrURL") {
                    found.append("\(url.lastPathComponent):\(i + 1)")
                }
            }
        }
        return found
    }

    func testNoSignedHintIsThisPhonesRelay() throws {
        XCTAssertEqual(try loopbackHintLines(), [])
    }

    func testScanSeesTheReplyHintSites() throws {
        // Positive control: the scan reads the files that set hints.
        let src = try String(contentsOf: app.appendingPathComponent("Views/Articles/ArticleReaderView.swift"), encoding: .utf8)
        XCTAssertTrue(src.contains("relayHint: ConfigService.shared.config.replyRelayHint"))
        let poll = try String(contentsOf: app.appendingPathComponent("Services/PollStore.swift"), encoding: .utf8)
        XCTAssertTrue(poll.contains("?? ConfigService.shared.config.replyRelayHint"))
        let repost = try String(contentsOf: app.appendingPathComponent("Services/PendingPostManager.swift"), encoding: .utf8)
        XCTAssertTrue(repost.contains("?? ConfigService.shared.config.replyRelayHint"))
    }
}
