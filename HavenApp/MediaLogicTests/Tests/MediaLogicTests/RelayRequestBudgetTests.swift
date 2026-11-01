import XCTest
@testable import MediaLogic

/// relay.damus.io bans IPs that send it too many requests a day (2026-10-31):
/// the lookups that fire on every scroll leave it out and batch more slowly.
final class RelayRequestBudgetTests: XCTestCase {
    func testScrollLookupsLeaveDamusOut() {
        XCTAssertFalse(RelayRequestBudget.profileIndexRelays.contains(RelayRequestBudget.damus))
        XCTAssertFalse(RelayRequestBudget.fallbackNoteRelays.contains(RelayRequestBudget.damus))
        XCTAssertFalse(RelayRequestBudget.liveRingRelays(feedRelays: [RelayRequestBudget.damus]).contains(RelayRequestBudget.damus))
    }

    /// zap.stream alone went stale (2026-11-01); rings also ask the feed relays.
    func testLiveRingAsksZapStreamAndFeedRelays() {
        XCTAssertEqual(RelayRequestBudget.liveRingRelays(feedRelays: []), ["wss://relay.zap.stream"])
        XCTAssertEqual(RelayRequestBudget.liveRingRelays(feedRelays: ["wss://nos.lol", RelayRequestBudget.damus,
                                                                      "wss://relay.zap.stream", "wss://nos.lol"]),
                       ["wss://relay.zap.stream", "wss://nos.lol"])
        let many = (1...10).map { "wss://r\($0).example" }
        XCTAssertEqual(RelayRequestBudget.liveRingRelays(feedRelays: many).count, RelayRequestBudget.liveRingMaxRelays)
    }

    func testLookupsStillHaveSomewhereToAsk() {
        XCTAssertTrue(RelayRequestBudget.profileIndexRelays.contains("wss://purplepag.es"))
        // The two last stops that found most missing notes on 2026-10-16.
        XCTAssertEqual(Array(RelayRequestBudget.fallbackNoteRelays.suffix(2)),
                       ["wss://relay.nostr.net", "wss://relay.fountain.fm"])
    }

    func testBatchWindows() {
        XCTAssertEqual(RelayRequestBudget.profileFlushInterval, 2)
        XCTAssertEqual(RelayRequestBudget.liveRingBatchDelay, 3)
        XCTAssertEqual(RelayRequestBudget.noteFetchWindow, 1)
        // A socket closes only after several ticks without use, and a REQ is
        // closed before the next one could pile onto it twice over.
        XCTAssertGreaterThan(RelayRequestBudget.profileSocketIdle, RelayRequestBudget.profileFlushInterval * 5)
        XCTAssertLessThan(RelayRequestBudget.profileSubscriptionSeconds, RelayRequestBudget.profileSocketIdle)
    }

    /// The services read the budget, not their own copies of the old numbers.
    func testServicesUseTheBudget() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../HavenApp/Services").standardized
        func src(_ path: String) throws -> String { try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) }
        let profiles = try src("Nostr/NostrService+Profiles.swift")
        XCTAssertTrue(profiles.contains("Timer.publish(every: RelayRequestBudget.profileFlushInterval"))
        XCTAssertTrue(profiles.contains("profileLookupClients[key]"))
        XCTAssertFalse(profiles.contains("for url in uniqueRelays {\n            let client = WebSocketClient()"))
        XCTAssertTrue(try src("NostrService.swift").contains("static let profileIndexRelays = RelayRequestBudget.profileIndexRelays"))
        XCTAssertTrue(try src("FeedService.swift").contains("static let fallbackNoteRelays = RelayRequestBudget.fallbackNoteRelays"))
        XCTAssertTrue(try src("Feed/FeedService+NoteFetching.swift").contains("withTimeInterval: RelayRequestBudget.noteFetchWindow"))
        let live = try src("LiveStatusService.swift")
        XCTAssertTrue(live.contains("RelayRequestBudget.liveRingBatchDelay"))
        XCTAssertTrue(live.contains("RelayRequestBudget.liveRingRelays(feedRelays: ConfigService.shared.config.activeFeedRelays)"))
        XCTAssertFalse(live.contains("LiveFeedService.relayURLs"))
    }
}
