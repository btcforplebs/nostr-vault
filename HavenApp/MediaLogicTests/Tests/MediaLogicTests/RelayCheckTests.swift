import XCTest
@testable import MediaLogic

final class RelayCheckTests: XCTestCase {
    private let defaults = ["wss://relay.primal.net", "wss://nos.lol", "wss://nostr.mom"]

    func testTheirWriteRelaysComeFirstThenDefaultsWithoutDuplicates() {
        let tags = [["r", "wss://relay.damus.io"], ["r", "wss://nostr.wine/", "write"],
                    ["r", "wss://read.only", "read"], ["r", "WSS://NOS.LOL"], ["p", "x"]]
        let rows = RelayCheck.rows(relayListTags: tags, defaults: defaults)
        XCTAssertEqual(rows.map(\.url), ["wss://relay.damus.io", "wss://nostr.wine", "wss://nos.lol",
                                         "wss://relay.primal.net", "wss://nostr.mom"])
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
        XCTAssertEqual(RelayCheck.importList(rows), ["wss://relay.primal.net", "wss://nos.lol"])
        rows[1].result = .refused; rows[1].isOn = false
        XCTAssertEqual(RelayCheck.summary(rows), "1 relay is ready to import from. 1 didn't answer, so we'll skip it. 1 doesn't keep notes.")
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
}
