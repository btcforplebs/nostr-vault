import XCTest
@testable import MediaLogic

/// The wait before a backup or restore while the last relay run drains (2nd Import bug, 2026-11-04).
final class RelayDrainWaitTests: XCTestCase {
    func testWaitsUntilTheLastRunHasDrained() async {
        var polls = 0
        let done = await RelayDrainWait.wait(maxWait: 60, isDraining: { polls += 1; return polls < 4 }, sleep: { _ in })
        XCTAssertTrue(done)
        XCTAssertEqual(polls, 4)
    }

    func testGivesUpAfterMaxWait() async {
        var clock = Date(timeIntervalSince1970: 0)
        let done = await RelayDrainWait.wait(maxWait: 10, now: { clock }, isDraining: { true },
                                             sleep: { clock = clock.addingTimeInterval(TimeInterval($0) / 1e9) })
        XCTAssertFalse(done)
        XCTAssertGreaterThanOrEqual(clock.timeIntervalSince1970, 10)
    }

    func testNoWaitWhenNothingIsDraining() async {
        var slept = false
        let done = await RelayDrainWait.wait(maxWait: 60, isDraining: { false }, sleep: { _ in slept = true })
        XCTAssertTrue(done)
        XCTAssertFalse(slept)
    }

    func testBoundMatchesAndroid() {
        XCTAssertEqual(RelayDrainWait.maxWait, 180, "Android RelayDrainState.MAX_WAIT_MS = 3 min")
    }
}
