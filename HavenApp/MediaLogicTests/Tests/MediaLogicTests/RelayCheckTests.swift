import XCTest
@testable import MediaLogic

final class RelayCheckTests: XCTestCase {
    private let defaults = ["wss://relay.primal.net", "wss://relay.snort.social", "wss://nostr-pub.wellorder.net"]

    func testTheirWriteRelaysComeFirstThenDefaultsWithoutDuplicates() {
        let tags = [["r", "wss://relay.damus.io"], ["r", "wss://nostr.wine/", "write"],
                    ["r", "wss://read.only", "read"], ["r", "WSS://RELAY.SNORT.SOCIAL"], ["p", "x"]]
        let rows = RelayCheck.rows(relayListTags: tags, defaults: defaults)
        XCTAssertEqual(rows.map(\.url), ["wss://relay.damus.io", "wss://nostr.wine", "wss://relay.snort.social",
                                         "wss://relay.primal.net", "wss://nostr-pub.wellorder.net"])
        XCTAssertEqual(rows.map(\.isYours), [true, true, true, false, false])
    }

    func testNoRelayListMeansDefaults() {
        XCTAssertEqual(RelayCheck.rows(relayListTags: [], defaults: defaults).map(\.url), defaults)
    }

    func testResults() {
        XCTAssertEqual(RelayCheck.Result(answeredAfter: 0.4, hasNotes: true), .ready(seconds: 0.4, hasNotes: true))
        XCTAssertEqual(RelayCheck.Result(answeredAfter: 3.4, hasNotes: true), .slow(seconds: 3.4, hasNotes: true))
        XCTAssertEqual(RelayCheck.Result(answeredAfter: nil, hasNotes: false), .notAnswering)
        XCTAssertEqual(RelayCheck.Result(answeredAfter: 9, hasNotes: true), .notAnswering)
    }

    /// Dead relays are off so the import can't stall on them; a slow relay
    /// is only worth waiting for if it has their notes.
    func testDefaultPicks() {
        XCTAssertTrue(RelayCheck.Result.ready(seconds: 1, hasNotes: false).onByDefault)
        XCTAssertTrue(RelayCheck.Result.slow(seconds: 3, hasNotes: true).onByDefault)
        XCTAssertFalse(RelayCheck.Result.slow(seconds: 3, hasNotes: false).onByDefault)
        XCTAssertFalse(RelayCheck.Result.notAnswering.onByDefault)
        XCTAssertFalse(RelayCheck.Result.refused.onByDefault)
    }

    func testSummaryAndImportList() {
        var rows = RelayCheck.rows(relayListTags: [], defaults: defaults)
        rows[0].isOn = true; rows[0].result = .ready(seconds: 1, hasNotes: true)
        rows[1].isOn = true; rows[1].result = .ready(seconds: 1, hasNotes: true)
        rows[2].result = .notAnswering
        XCTAssertEqual(RelayCheck.summary(rows), "2 relays are ready to import from. 1 didn't answer, so we'll skip it.")
        XCTAssertEqual(RelayCheck.importList(rows), ["wss://relay.primal.net", "wss://relay.snort.social"])
        rows[1].result = .refused; rows[1].isOn = false
        XCTAssertEqual(RelayCheck.summary(rows), "1 relay is ready to import from. 1 didn't answer, so we'll skip it. 1 won't share notes.")
        rows[0].isOn = false; rows[1].isOn = false
        XCTAssertTrue(RelayCheck.summary(rows).hasPrefix("No relays"))
    }

    func testNormalize() {
        XCTAssertEqual(RelayCheck.normalize("relay.example.com"), "wss://relay.example.com")
        XCTAssertEqual(RelayCheck.normalize(" wss://Relay.Example.com/ "), "wss://relay.example.com")
        XCTAssertEqual(RelayCheck.normalize("wss://r.example.com:7777/inbox"), "wss://r.example.com:7777/inbox")
        XCTAssertNil(RelayCheck.normalize("https://example.com"))
        XCTAssertNil(RelayCheck.normalize("not a relay"))
        XCTAssertNil(RelayCheck.normalize("localhost"))
    }

    /// relay.nostr.build answers kind-1 REQs with AUTH, then
    /// CLOSED "auth-required: …" (checked 2026-10-07).
    func testClosedReasons() {
        XCTAssertEqual(RelayCheck.closedResult(reason: "auth-required: authenticate with AUTH before subscribing"), .needsSignIn)
        XCTAssertEqual(RelayCheck.closedResult(reason: "ERROR: bad req: filter validation failed: kind not allowed: 1"), .refused)
        XCTAssertEqual(RelayCheck.closedResult(reason: nil), .refused)
        XCTAssertFalse(RelayCheck.Result.needsSignIn.canImport)
    }

    // MARK: Their own servers (setup import, read only)

    func testOwnWriteRelaysSkipReadOnlyWsAndLANAndDuplicates() {
        let tags = [["r", "wss://relay.damus.io"], ["r", "wss://nostr.wine/", "write"],
                    ["r", "wss://read.only", "read"], ["r", "ws://relay.example.com"],
                    ["r", "wss://192.168.1.20:4869"], ["r", "wss://10.0.0.5"], ["r", "wss://172.20.1.1"],
                    ["r", "wss://100.70.1.1"], ["r", "wss://127.0.0.1:4869"], ["r", "wss://umbrel.local"],
                    ["r", "wss://box.lan"], ["r", "wss://localhost:4869"], ["r", "WSS://Relay.Damus.io/"],
                    ["r", "wss://172.32.0.1"], ["r", "wss://[fd00::1]:4869"], ["r", "wss://box.tail1234.ts.net"],
                    ["p", "x"]]
        XCTAssertEqual(RelayCheck.ownWriteRelays(relayListTags: tags),
                       ["wss://relay.damus.io", "wss://nostr.wine", "wss://172.32.0.1"])
    }

    func testOwnServersSkippedInTheCheckRowsToo() {
        let rows = RelayCheck.rows(relayListTags: [["r", "ws://relay.example.com"], ["r", "wss://192.168.1.2"]],
                                   defaults: defaults)
        XCTAssertEqual(rows.map(\.url), defaults)
    }

    func testImportSeedsPutOwnServersOnTopOfTheFixedListWithoutDuplicates() {
        XCTAssertEqual(RelayCheck.importSeeds(fixed: defaults, own: ["wss://relay.snort.social", "wss://nostr.wine"]),
                       defaults + ["wss://nostr.wine"])
        XCTAssertEqual(RelayCheck.importSeeds(fixed: defaults, own: []), defaults)
    }

    func testSplitPicksKeepsOwnServersOutOfTheSavedList() {
        let tags = [["r", "wss://nostr.wine"], ["r", "wss://relay.snort.social"], ["r", "wss://dead.example"]]
        var rows = RelayCheck.rows(relayListTags: tags, defaults: defaults)
        for i in rows.indices { rows[i].isOn = rows[i].url != "wss://dead.example" }
        let picks = RelayCheck.splitPicks(rows, defaults: defaults)
        XCTAssertEqual(picks.own, ["wss://nostr.wine"])
        XCTAssertEqual(picks.fixed, ["wss://relay.snort.social", "wss://relay.primal.net", "wss://nostr-pub.wellorder.net"])
    }
}
