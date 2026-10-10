import XCTest
@testable import MediaLogic

/// iPhone kiosk mode pauses at the serve limit and shares again by itself.
final class KioskCapPauseTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testSharingUnderTheLimitDoesNothing() {
        XCTAssertEqual(KioskCapPause.step(capReached: false, pausedUntil: nil, resuming: false, now: now), .none)
    }

    func testTheLimitPausesForTheCoolDownInsteadOfTurningKioskOff() {
        XCTAssertEqual(
            KioskCapPause.step(capReached: true, pausedUntil: nil, resuming: false, now: now),
            .pause(until: now.addingTimeInterval(60 * 60))
        )
    }

    func testAPauseInProgressIsNotRestartedByLaterPolls() {
        // The engine keeps reporting the limit for the whole pause; the
        // deadline set by the first poll must not slide forward.
        let until = now.addingTimeInterval(600)
        XCTAssertEqual(KioskCapPause.step(capReached: true, pausedUntil: until, resuming: false, now: now), .none)
    }

    func testSharingResumesOnceTheCoolDownEnds() {
        XCTAssertEqual(KioskCapPause.step(capReached: true, pausedUntil: now, resuming: false, now: now), .resume)
        XCTAssertEqual(
            KioskCapPause.step(capReached: true, pausedUntil: now, resuming: false, now: now.addingTimeInterval(5)),
            .resume
        )
    }

    func testAResumeInFlightNeitherPausesAgainNorResumesTwice() {
        // Until the share-again call lands the engine still reports the limit.
        XCTAssertEqual(KioskCapPause.step(capReached: true, pausedUntil: nil, resuming: true, now: now), .none)
        XCTAssertEqual(KioskCapPause.step(capReached: true, pausedUntil: now, resuming: true, now: now), .none)
    }
}
