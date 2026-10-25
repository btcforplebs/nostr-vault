import XCTest
@testable import MediaLogic

final class PublishTargetsTests: XCTestCase {
    private let appDefaults = ["wss://relay.btcforplebs.com", "wss://relay.damus.io", "wss://relay.snort.social"]
    // The 2026-10-25 reply's author: kind 10002 with unmarked r tags.
    private let authorWrite = ["wss://relay.nortis.tech", "wss://relay.nostr.build", "wss://nos.lol", "wss://relay.primal.net"]

    func testAuthorsWriteRelaysDecideAndAppRelaysStillGetIt() {
        let plan = PublishTargets.plan(authorWriteRelays: authorWrite, appWriteRelays: appDefaults)
        XCTAssertEqual(plan.confirmed, authorWrite)
        XCTAssertEqual(plan.alsoSend, appDefaults)
    }

    func testAppRelayAcceptingDoesNotCountAsPosted() {
        let plan = PublishTargets.plan(authorWriteRelays: authorWrite, appWriteRelays: appDefaults)
        var tally = BroadcastTally(relayCount: plan.confirmed.count)
        for relay in plan.confirmed { _ = tally.record(relay: relay, success: false, message: "connection failed") }
        XCTAssertEqual(tally.outcome, .refused)
        XCTAssertFalse(plan.confirmed.contains("wss://relay.damus.io"))
    }

    func testNoRelayListFallsBackToAppRelays() {
        XCTAssertEqual(PublishTargets.plan(authorWriteRelays: nil, appWriteRelays: appDefaults),
                       PublishTargets.Plan(confirmed: appDefaults, alsoSend: []))
        XCTAssertEqual(PublishTargets.plan(authorWriteRelays: [], appWriteRelays: appDefaults),
                       PublishTargets.Plan(confirmed: appDefaults, alsoSend: []))
    }

    func testRelayInBothListsIsSentOnceAsTheAuthors() {
        let plan = PublishTargets.plan(authorWriteRelays: ["wss://nos.lol/", "wss://relay.damus.io"], appWriteRelays: appDefaults)
        XCTAssertEqual(plan.confirmed, ["wss://nos.lol", "wss://relay.damus.io"])
        XCTAssertEqual(plan.alsoSend, ["wss://relay.btcforplebs.com", "wss://relay.snort.social"])
    }

    func testLoopbackNeverDecides() {
        let plan = PublishTargets.plan(authorWriteRelays: ["ws://127.0.0.1:3355", "wss://nos.lol"], appWriteRelays: appDefaults)
        XCTAssertEqual(plan.confirmed, ["wss://nos.lol"])
    }
}
