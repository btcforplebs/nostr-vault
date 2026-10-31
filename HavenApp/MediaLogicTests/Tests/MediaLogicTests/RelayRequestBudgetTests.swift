import XCTest
@testable import MediaLogic

/// relay.damus.io bans IPs that send it too many requests a day (2026-10-31):
/// the lookups that fire on every scroll leave it out and batch more slowly.
final class RelayRequestBudgetTests: XCTestCase {
    func testScrollLookupsLeaveDamusOut() {
        XCTAssertFalse(RelayRequestBudget.profileIndexRelays.contains(RelayRequestBudget.damus))
        XCTAssertFalse(RelayRequestBudget.fallbackNoteRelays.contains(RelayRequestBudget.damus))
        XCTAssertEqual(RelayRequestBudget.liveRingRelays, ["wss://relay.zap.stream"])
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
        XCTAssertTrue(live.contains("for url in RelayRequestBudget.liveRingRelays"))
        XCTAssertFalse(live.contains("LiveFeedService.relayURLs"))
    }
}
