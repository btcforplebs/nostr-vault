import XCTest
@testable import MediaLogic

/// Where the app itself sends an event it just posted, besides this device's
/// relay. A reply has to leave the phone even when the local relay's blast
/// never runs.
final class DirectBroadcastRelaysTests: XCTestCase {

    private let blastr = ["wss://relay.primal.net", "wss://relay.btcforplebs.com"]

    func testNotesAndRepliesGoToTheBlastrRelays() {
        let reply = [["e", String(repeating: "a", count: 64), "", "root"], ["p", String(repeating: "b", count: 64)]]
        XCTAssertEqual(RelayConfiguration.directBroadcastRelays(kind: 1, tags: [], blastrRelays: blastr), blastr)
        XCTAssertEqual(RelayConfiguration.directBroadcastRelays(kind: 1, tags: reply, blastrRelays: blastr), blastr)
    }

    func testReactionsRepostsAndProfilesGoToo() {
        for kind in [0, 3, 5, 6, 7, 16, 1111, 30023] {
            XCTAssertEqual(RelayConfiguration.directBroadcastRelays(kind: kind, tags: [], blastrRelays: blastr), blastr, "kind \(kind)")
        }
    }

    func testNoBlastrRelaysFallsBackRatherThanSendingNowhere() {
        XCTAssertEqual(RelayConfiguration.directBroadcastRelays(kind: 1, tags: [], blastrRelays: []),
                       RelayConfiguration.fallbackBroadcastRelays)
        XCTAssertFalse(RelayConfiguration.fallbackBroadcastRelays.isEmpty)
    }

    func testDMRelayListAlsoGoesToTheRelaysItNames() {
        let tags = [["relay", "wss://inbox.example.com"], ["relay", "wss://relay.primal.net"], ["p", "x"]]
        XCTAssertEqual(RelayConfiguration.directBroadcastRelays(kind: 10050, tags: tags, blastrRelays: blastr),
                       blastr + ["wss://inbox.example.com"])
    }

    /// Only a 10050 names its own destinations; relay tags on anything else
    /// are content, not routing.
    func testRelayTagsOnOtherKindsAreNotDestinations() {
        let tags = [["relay", "wss://inbox.example.com"]]
        XCTAssertEqual(RelayConfiguration.directBroadcastRelays(kind: 1, tags: tags, blastrRelays: blastr), blastr)
    }

    /// A 10063 goes to every write relay in the owner's 10002 and to
    /// purplepag.es (2026-10-22: four lists in a row each reached one relay).
    func testServerListGoesToEveryOwnerWriteRelayAndPurplepages() {
        let write = ["wss://relay.damus.io", "wss://relay.snort.social/", "wss://relay.primal.net/"]
        XCTAssertEqual(RelayConfiguration.directBroadcastRelays(kind: 10063, tags: [], blastrRelays: blastr, ownerWriteRelays: write),
                       blastr + ["wss://relay.damus.io", "wss://relay.snort.social/", "wss://purplepag.es"])
        XCTAssertEqual(RelayConfiguration.directBroadcastRelays(kind: 10063, tags: [], blastrRelays: blastr),
                       blastr + ["wss://purplepag.es"], "no 10002 cached yet: purplepag.es still")
    }

    func testServerListNeverGoesToThisMachineOrPlainWs() {
        let write = ["ws://127.0.0.1:4869", "wss://localhost/", "ws://relay.example.com", "not a url", "wss://nos.lol"]
        XCTAssertEqual(RelayConfiguration.directBroadcastRelays(kind: 10063, tags: [], blastrRelays: blastr, ownerWriteRelays: write),
                       blastr + ["wss://nos.lol", "wss://purplepag.es"])
    }

    /// Only the 10063 widens: a note still goes where it went before.
    func testOwnerWriteRelaysDoNotWidenOtherKinds() {
        for kind in [0, 1, 3, 10002] {
            XCTAssertEqual(RelayConfiguration.directBroadcastRelays(kind: kind, tags: [], blastrRelays: blastr,
                                                                    ownerWriteRelays: ["wss://nos.lol"]), blastr, "kind \(kind)")
        }
    }
}
