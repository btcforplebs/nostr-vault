import simd
import XCTest
@testable import MediaLogic

/// Letting go of the globe is one motion: the release speed carries on,
/// dies away and lands in the slow drift the way it was thrown, with no
/// stop and no wait between (Logen, 11/03).
final class GlobeFlickTests: XCTestCase {
    /// The angle turned over one short step, radians.
    private func turned(_ camera: inout GlobeCamera, dt: Double, at now: Double) -> Double {
        let before = camera.orientation
        camera.step(dt: dt, now: now, reduceMotion: false)
        return 2 * acos(min(1, abs(simd_dot(before.vector, camera.orientation.vector))))
    }

    private func released(vx: Double, vy: Double = 0) -> GlobeCamera {
        var camera = GlobeCamera()
        camera.keepsDrifting = true
        camera.drag(dx: 40, dy: 0, at: 0)
        camera.dragging = true
        camera.dragging = false
        camera.flick(vx: vx, vy: vy, at: 0, reduceMotion: false)
        return camera
    }

    func testTheReleaseSpeedCarriesOverExactly() {
        var camera = released(vx: 300, vy: -120)
        let rate = turned(&camera, dt: 1 / 120, at: 1 / 120) * 120
        let thrown = (300.0 * 300 + 120 * 120).squareRoot() * GlobeCamera.flickTurn
        XCTAssertEqual(rate, thrown, accuracy: thrown * 0.02)
    }

    func testAGentleLetGoNeverStopsOrWaits() {
        // Slower than the old 350 pt/s floor, which stopped it dead.
        var camera = released(vx: 120)
        var now = 0.0
        while now < 6 {
            now += 1 / 120
            XCTAssertGreaterThan(turned(&camera, dt: 1 / 120, at: now), 0, "stopped at \(now)s")
            // Within two seconds it is turning at the drift to the eye.
            if abs(now - 2) < 1e-9 { XCTAssertLessThan(simd_length(camera.spin), GlobeCamera.driftSpeed * 0.1) }
        }
        XCTAssertEqual(camera.spin, .zero)
        XCTAssertEqual(camera.drift, GlobeCamera.driftSpeed)
    }

    func testEvenAStillLetGoEasesStraightIntoTheDrift() {
        var camera = released(vx: 0)
        var now = 0.0
        var last = 0.0
        while now < 2 {
            now += 1 / 120
            let step = turned(&camera, dt: 1 / 120, at: now)
            XCTAssertGreaterThan(step, 0)
            XCTAssertGreaterThanOrEqual(step, last - 1e-9, "the turn should only speed up into the drift")
            last = step
        }
    }

    func testTheDriftTurnsTheWayItWasThrown() {
        var left = released(vx: -900), right = released(vx: 900)
        for i in 1...(120 * 8) {
            left.step(dt: 1 / 120, now: Double(i) / 120, reduceMotion: false)
            right.step(dt: 1 / 120, now: Double(i) / 120, reduceMotion: false)
        }
        XCTAssertEqual(left.drift, -GlobeCamera.driftSpeed)
        XCTAssertEqual(right.drift, GlobeCamera.driftSpeed)
        XCTAssertEqual(left.spin, .zero)
        // A straight up-and-down throw keeps the way it had.
        left.flick(vx: 0, vy: 900, at: 8, reduceMotion: false)
        XCTAssertEqual(left.drift, -GlobeCamera.driftSpeed)
    }

    func testTheSpeedOnlyEverFallsTowardTheDrift() {
        // No dip below the drift and back: one smooth slow-down.
        var camera = released(vx: 1500)
        var now = 0.0
        var last = Double.infinity
        while now < 6 {
            now += 1 / 120
            let step = turned(&camera, dt: 1 / 120, at: now)
            XCTAssertLessThanOrEqual(step, last + 1e-9)
            XCTAssertGreaterThanOrEqual(step * 120, GlobeCamera.driftSpeed * 0.999)
            last = step
        }
    }

    func testAHardThrowGlidesFurtherAndLongerThanAGentleOne() {
        func glide(_ vx: Double) -> (angle: Double, seconds: Double) {
            var camera = released(vx: vx)
            var now = 0.0, angle = 0.0, settled = 0.0
            while now < 10 {
                now += 1 / 120
                angle += turned(&camera, dt: 1 / 120, at: now)
                if camera.spin != .zero { settled = now }
            }
            return (angle, settled)
        }
        let hard = glide(2000), gentle = glide(300)
        XCTAssertGreaterThan(hard.angle, gentle.angle * 2)
        XCTAssertGreaterThan(hard.seconds, gentle.seconds)
    }

    func testWithSpinningOffAThrowStillGlidesButEndsStill() {
        var camera = GlobeCamera()
        camera.keepsDrifting = true
        camera.drifts = false
        camera.flick(vx: 900, vy: 0, at: 0, reduceMotion: false)
        var now = 0.0
        var moved = 0.0
        while now < 10 { now += 1 / 30; moved += turned(&camera, dt: 1 / 30, at: now) }
        XCTAssertGreaterThan(moved, 0.5)
        XCTAssertEqual(camera.drift, 0)
        XCTAssertFalse(camera.wantsFrames(now: now, reduceMotion: false))
    }

    func testAPinchStillWaitsBeforeTheDrift() {
        // Only a let-go starts the drift at once; zooming waits as before.
        var camera = GlobeCamera()
        camera.touch(at: 0)
        var now = 0.0
        while now < GlobeCamera.driftAfter - 0.1 {
            now += 1 / 120
            XCTAssertEqual(turned(&camera, dt: 1 / 120, at: now), 0)
        }
    }
}
