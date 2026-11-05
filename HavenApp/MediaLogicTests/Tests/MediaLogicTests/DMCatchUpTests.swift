import XCTest
@testable import MediaLogic

/// DM catch-up used one timestamp for every account and moved it even when
/// no relay answered.
final class DMCatchUpTests: XCTestCase {
    func testEachAccountHasItsOwnMark() {
        XCTAssertNotEqual(DMCatchUp.key(account: "aa"), DMCatchUp.key(account: "bb"))
        XCTAssertNotEqual(DMCatchUp.key(account: "aa"), DMCatchUp.legacyKey)
    }

    func testAFetchNoRelayAnsweredDoesNotMoveTheMark() {
        let run = DMCatchUp(account: "aa", startedAt: 2_000)
        XCTAssertEqual(run.nextMark(previous: 1_000), 1_000)
    }

    func testAFetchARelayFinishedMovesTheMarkToItsStart() {
        var run = DMCatchUp(account: "aa", startedAt: 2_000)
        run.relayFinished()
        XCTAssertEqual(run.nextMark(previous: 1_000), 2_000)
    }

    func testTheMarkNeverMovesBack() {
        var run = DMCatchUp(account: "aa", startedAt: 2_000)
        run.relayFinished()
        XCTAssertEqual(run.nextMark(previous: 3_000), 3_000)
    }
}
