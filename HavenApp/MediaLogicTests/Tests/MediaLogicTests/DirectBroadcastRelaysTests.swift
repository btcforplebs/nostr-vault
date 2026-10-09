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
}
