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
}
