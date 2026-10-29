import XCTest
@testable import MediaLogic

/// iPhone kiosk mode pauses strangers at the serve limit and shares again by itself.
final class KioskCapPauseTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testSharingUnderTheLimitDoesNothing() {
        XCTAssertEqual(KioskCapPause.step(capReached: false, pausedUntil: nil, now: now, shareAgainAt: { XCTFail("not asked"); return now }), .none)
    }

    func testTheLimitPausesUntilTheTimeTheBudgetGivesInsteadOfTurningKioskOff() {
        let tomorrow = now.addingTimeInterval(9 * 3600)
        XCTAssertEqual(
            KioskCapPause.step(capReached: true, pausedUntil: nil, now: now, shareAgainAt: { tomorrow }),
            .pause(until: tomorrow)
        )
    }

    func testAPauseInProgressIsNotRestartedByLaterPolls() {
        // The engine keeps reporting the limit for the whole pause; the
        // deadline set by the first poll must not slide forward.
        let until = now.addingTimeInterval(600)
        XCTAssertEqual(KioskCapPause.step(capReached: true, pausedUntil: until, now: now, shareAgainAt: { XCTFail("not asked"); return now }), .none)
    }

    func testSharingResumesOnceThePauseEnds() {
        XCTAssertEqual(KioskCapPause.step(capReached: true, pausedUntil: now, now: now, shareAgainAt: { now }), .resume)
        XCTAssertEqual(KioskCapPause.step(capReached: true, pausedUntil: now, now: now.addingTimeInterval(5), shareAgainAt: { now }), .resume)
    }

    func testNoLimitIsNeverSentAsZeroBecauseTheEngineReadsZeroAsOneGigabyte() {
        XCTAssertEqual(KioskCapPause.engineServeLimit(0), .max)
        XCTAssertEqual(KioskCapPause.engineServeLimit(250 << 20), 250 << 20)
    }
}
