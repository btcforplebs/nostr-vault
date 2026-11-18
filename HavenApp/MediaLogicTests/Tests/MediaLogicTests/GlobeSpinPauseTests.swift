import XCTest
@testable import MediaLogic

/// Logen 7eee63d2: "stop flying thing when we pause spinning". While the
/// WoT globe's spin is paused no arrival flies, so the clock can sleep.
final class GlobeSpinPauseTests: XCTestCase {
    private func camera(touchedAt t: Double) -> GlobeCamera {
        var c = GlobeCamera()
        c.touch(at: t)
        return c
    }

    func testSpinningRightAfterATouchIsNotPaused() {
        XCTAssertFalse(camera(touchedAt: 100).spinPaused(now: 105))
    }

    func testUntouchedPastSleepAfterWithTheDriftStoppedIsPaused() {
        let c = camera(touchedAt: 100)
        XCTAssertFalse(c.spinPaused(now: 100 + GlobeCamera.sleepAfter - 0.1))
        XCTAssertTrue(c.spinPaused(now: 100 + GlobeCamera.sleepAfter))
    }

    func testStillEasingOutIsNotPausedYet() {
        var c = camera(touchedAt: 0)
        c.drift = 0.01
        XCTAssertFalse(c.spinPaused(now: 100), "the drift is still slowing")
    }

    func testATouchResumes() {
        var c = camera(touchedAt: 0)
        XCTAssertTrue(c.spinPaused(now: 100))
        c.touch(at: 100)
        XCTAssertFalse(c.spinPaused(now: 100.5))
    }

    func testAnyMotionUnderAFingerIsNotPaused() {
        var c = camera(touchedAt: 0)
        c.dragging = true
        XCTAssertFalse(c.spinPaused(now: 100))
        c.dragging = false
        c.spin = SIMD3(0, 0.3, 0)
        XCTAssertFalse(c.spinPaused(now: 100))
    }

    func testSpinningSwitchedOffIsPausedWhenStill() {
        var c = camera(touchedAt: 100)
        c.drifts = false
        XCTAssertTrue(c.spinPaused(now: 101))
    }

    func testAGlobeThatKeepsDriftingNeverPauses() {
        var c = camera(touchedAt: 0)
        c.keepsDrifting = true
        XCTAssertFalse(c.spinPaused(now: 10_000))
    }
}
