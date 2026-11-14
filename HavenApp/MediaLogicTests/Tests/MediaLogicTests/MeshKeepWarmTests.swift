import XCTest
@testable import MediaLogic

/// The iPhone keeps its running mesh across a short trip out of the app
/// instead of a stop on leaving and a cold start on return (Logen 2026-11-14).
final class MeshKeepWarmTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testAShortTripKeepsTheEngine() {
        var clock = MeshKeepWarm.Clock()
        let trip = clock.left(at: t0)
        XCTAssertNotNil(trip)
        XCTAssertEqual(clock.returned(at: t0.addingTimeInterval(6)), .keep, "back in 6 s: no stop, no cold start")
        XCTAssertFalse(clock.graceEnded(trip: trip!), "the grace timer that fires later stops nothing")
    }

    func testTheGraceStopsTheEngineWhileStillAway() {
        var clock = MeshKeepWarm.Clock()
        let trip = clock.left(at: t0)!
        XCTAssertTrue(clock.graceEnded(trip: trip))
    }

    func testAnEarlierTripsTimerNeverStopsALaterTrip() {
        var clock = MeshKeepWarm.Clock()
        let first = clock.left(at: t0)!
        _ = clock.returned(at: t0.addingTimeInterval(3))
        let second = clock.left(at: t0.addingTimeInterval(10))!
        XCTAssertFalse(clock.graceEnded(trip: first), "fires at 25 s, only 15 s into the second trip")
        XCTAssertTrue(clock.graceEnded(trip: second))
    }

    func testOneTripIsCountedOnceAcrossObservers() {
        var clock = MeshKeepWarm.Clock()
        XCTAssertNotNil(clock.left(at: t0))
        XCTAssertNil(clock.left(at: t0.addingTimeInterval(0.1)), "kiosk and client both hear didEnterBackground")
    }

    func testALongTripFindsAFrozenEngineAndStartsFresh() {
        // iOS froze the app before the grace timer ran: the engine is still
        // marked up, its socket is gone.
        var clock = MeshKeepWarm.Clock()
        _ = clock.left(at: t0)
        XCTAssertEqual(clock.returned(at: t0.addingTimeInterval(MeshKeepWarm.grace + 30)), .restartIfUp)
    }

    func testAReturnWithoutATripIsNothing() {
        var clock = MeshKeepWarm.Clock()
        XCTAssertEqual(clock.returned(at: t0), .none, "the first activation after launch")
        _ = clock.left(at: t0)
        _ = clock.returned(at: t0.addingTimeInterval(1))
        XCTAssertEqual(clock.returned(at: t0.addingTimeInterval(2)), .none)
    }

    func testTheGraceEndsBeforeIOSFreezesTheApp() {
        // iOSAppDelegate's background task: about 30 s.
        XCTAssertLessThan(MeshKeepWarm.grace, 30)
        XCTAssertGreaterThanOrEqual(MeshKeepWarm.grace, 20, "covers most trips (175 of 295 were under 20 s)")
    }
}
