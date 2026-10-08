import XCTest
@testable import MediaLogic

/// The relay matrix grid: one row per relay, its jobs read from and written
/// back to the separate lists every feature uses.
final class RelayMatrixTests: XCTestCase {

    private let lists = RelayMatrix.Lists(
        read: ["wss://a.example", "wss://b.example"],
        write: ["wss://A.example/", "wss://w.example"],
        dms: ["wss://d.example"],
        search: ["wss://s.example"],
        importing: ["wss://b.example"])

    func testOneRowPerRelayInFirstSeenOrder() {
        let rows = RelayMatrix.rows(lists)
        XCTAssertEqual(rows.map(\.url), ["wss://a.example", "wss://b.example", "wss://w.example", "wss://d.example", "wss://s.example"])
        XCTAssertEqual(rows[0].jobs, [.read, .write])
        XCTAssertEqual(rows[1].jobs, [.read, .importing])
        XCTAssertEqual(rows[3].jobs, [.dms])
    }

    func testPinnedRelayHasNoRow() {
        let rows = RelayMatrix.rows(lists, pinned: ["wss://a.example/", "wss://D.example", ""])
        XCTAssertFalse(rows.contains { $0.url == "wss://a.example" })
        XCTAssertFalse(rows.contains { $0.url == "wss://d.example" })
        XCTAssertEqual(rows.count, 3)
    }

    func testTurningAJobOffRemovesEverySpelling() {
        let result = RelayMatrix.setting(.write, false, for: "wss://a.example", in: lists)
        XCTAssertEqual(result.write, ["wss://w.example"])
        XCTAssertEqual(result.read, lists.read)
    }

    func testTurningAJobOnAppendsOnceAndKeepsOrder() {
        let on = RelayMatrix.setting(.dms, true, for: "wss://a.example/", in: lists)
        XCTAssertEqual(on.dms, ["wss://d.example", "wss://a.example"])
        let again = RelayMatrix.setting(.write, true, for: "wss://a.example", in: lists)
        XCTAssertEqual(again.write, lists.write)
    }

    func testRemovingTakesTheRelayOutOfEveryJob() {
        let result = RelayMatrix.removing("wss://b.example", from: lists)
        XCTAssertEqual(result.read, ["wss://a.example"])
        XCTAssertEqual(result.importing, [])
        XCTAssertEqual(result.write, lists.write)
    }

    func testAddingStartsWithReadAndWrite() {
        let result = RelayMatrix.adding("wss://new.example", to: lists)
        XCTAssertEqual(result.read.last, "wss://new.example")
        XCTAssertEqual(result.write.last, "wss://new.example")
        XCTAssertEqual(result.dms, lists.dms)
    }

    func testTypedRelayURL() {
        XCTAssertEqual(RelayMatrix.relayURL(from: " relay.example.com/ "), "wss://relay.example.com")
        XCTAssertEqual(RelayMatrix.relayURL(from: "ws://127.0.0.1:3355"), "ws://127.0.0.1:3355")
        XCTAssertNil(RelayMatrix.relayURL(from: "https://relay.example.com"))
        XCTAssertNil(RelayMatrix.relayURL(from: "not a relay"))
        XCTAssertNil(RelayMatrix.relayURL(from: ""))
    }

    func testProblems() {
        let empty = RelayMatrix.Lists(read: [], write: [], dms: [], search: [], importing: [])
        XCTAssertEqual(RelayMatrix.problems(empty, ownDMInbox: "", unreachable: []),
                       [.noRead, .noWrite, .noDMs, .noSearch])
        XCTAssertEqual(RelayMatrix.problems(lists, ownDMInbox: "", unreachable: ["wss://w.example"]),
                       [.oneDM, .unreachable("wss://w.example")])
        // The owner's own inbox counts as a second DM relay.
        XCTAssertEqual(RelayMatrix.problems(lists, ownDMInbox: "wss://vault.example.com/inbox", unreachable: []), [])
    }

    // MARK: - Never connect

    func testBlockingRemovesFromEveryJobOnce() {
        let (after, blocked) = RelayMatrix.blocking("wss://a.example/", lists: lists, blocked: ["wss://x.example"])
        XCTAssertFalse(RelayMatrix.rows(after).contains { $0.id == "wss://a.example" })
        XCTAssertEqual(blocked, ["wss://x.example", "wss://a.example"])
        let (_, again) = RelayMatrix.blocking("WSS://A.example", lists: after, blocked: blocked)
        XCTAssertEqual(again, blocked)
        XCTAssertEqual(RelayMatrix.unblocking("wss://A.example/", blocked: again), ["wss://x.example"])
    }

    func testBlocklistMatchesHostAndExactPaths() {
        RelayBlocklist.set(["wss://bad.example/", "wss://host.example/private"])
        defer { RelayBlocklist.set([]) }
        XCTAssertTrue(RelayBlocklist.isBlocked("wss://bad.example"))
        XCTAssertTrue(RelayBlocklist.isBlocked("WSS://Bad.example/inbox"))
        XCTAssertTrue(RelayBlocklist.isBlocked("wss://host.example/private/"))
        XCTAssertFalse(RelayBlocklist.isBlocked("wss://host.example"))
        XCTAssertFalse(RelayBlocklist.isBlocked("wss://good.example"))
        // Another port on the same host is another relay.
        XCTAssertFalse(RelayBlocklist.isBlocked("wss://bad.example:8443"))
    }

    /// The app's own relay lives on loopback: a local relay can't be blocked,
    /// or blocking one would cut off every other local port too.
    func testBlocklistIgnoresLocalRelays() {
        RelayBlocklist.set(["ws://127.0.0.1:4869", "wss://localhost", "wss://bad.example:7777"])
        defer { RelayBlocklist.set([]) }
        XCTAssertFalse(RelayBlocklist.isBlocked("ws://127.0.0.1:4869"))
        XCTAssertFalse(RelayBlocklist.isBlocked("ws://127.0.0.1:3355/inbox"))
        XCTAssertFalse(RelayBlocklist.isBlocked("wss://localhost/inbox"))
        XCTAssertTrue(RelayBlocklist.isBlocked("wss://bad.example:7777/x"))
        XCTAssertFalse(RelayBlocklist.isBlocked("wss://bad.example"))
    }

    // MARK: - Recommended

    func testFollowSuggestionsRankByFollowsAndSkipTaken() {
        let outbox = [
            "p1": ["wss://popular.example", "wss://a.example", "wss://once.example"],
            "p2": ["wss://popular.example/", "wss://Popular.example", "wss://blocked.example"],
            "p3": ["wss://popular.example", "wss://second.example", "wss://blocked.example"],
            "p4": ["wss://second.example", "ws://127.0.0.1:4869", "wss://x.onion"],
            "p5": ["wss://localhost.example"],
        ]
        let suggestions = RelayMatrix.followSuggestions(
            follows: ["p1", "p2", "p3", "p4", "p4"], outbox: outbox,
            lists: lists, blocked: ["wss://blocked.example"])
        // p5 isn't followed; a.example is already Read; once.example has one follow.
        XCTAssertEqual(suggestions, [
            .init(url: "wss://popular.example", follows: 3),
            .init(url: "wss://second.example", follows: 2),
        ])
        XCTAssertEqual(RelayMatrix.followsWithRelayLists(follows: ["p1", "p9"], outbox: outbox), 1)
    }

    func testFastestSortsAnsweredAndSkipsTaken() {
        let ms = ["wss://slow.example": 400, "wss://quick.example": 90, "wss://a.example": 10]
        let fastest = RelayMatrix.fastest(
            ["wss://slow.example", "wss://down.example", "wss://quick.example/", "wss://a.example", "wss://gone.example"],
            milliseconds: ms, lists: lists, blocked: ["wss://gone.example"])
        XCTAssertEqual(fastest, ["wss://quick.example", "wss://slow.example"])
    }

    func testPublicRelay() {
        XCTAssertTrue(RelayMatrix.isPublicRelay("wss://relay.damus.io"))
        for url in ["ws://relay.damus.io", "wss://localhost", "wss://abc.onion", "wss://192.168.1.4",
                    "wss://172.20.0.1", "wss://10.0.0.1:4848", "wss://vault.local", "wss://nodots"] {
            XCTAssertFalse(RelayMatrix.isPublicRelay(url), url)
        }
        XCTAssertTrue(RelayMatrix.isPublicRelay("wss://172.40.0.1"))
    }

    func testFallbackProblemTextNamesTheRealFallbacks() {
        XCTAssertTrue(RelayMatrix.Problem.noWrite.detail.contains("relay.btcforplebs.com"))
        XCTAssertTrue(RelayMatrix.Problem.noRead.detail.contains("relay.primal.net"))
    }

    func testSearchIsAGridColumn() {
        XCTAssertTrue(RelayMatrix.Job.columns.contains(.search))
        XCTAssertFalse(RelayMatrix.Job.advanced.contains(.search))
        XCTAssertEqual(Set(RelayMatrix.Job.columns + RelayMatrix.Job.advanced), Set(RelayMatrix.Job.allCases))
    }

    func testAnEditProbesOnlyRelaysWithNoSpeedYet() {
        let known: Set<String> = [RelayMatrix.key("wss://a.example"), RelayMatrix.key("wss://b.example")]
        XCTAssertEqual(RelayMatrix.needingProbe(["wss://A.example/", "wss://b.example", "wss://new.example", ""], known: known),
                       ["wss://new.example"])
    }
}
