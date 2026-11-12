import XCTest
@testable import MediaLogic

final class StatusPulseRuleTests: XCTestCase {
    /// The CPU bug: a running vault kept the dot looping forever.
    func testRunningVaultHasASteadyDot() {
        XCTAssertFalse(StatusPulseRule.pulses(isRunning: true, isBooting: false, reduceMotion: false))
    }

    func testStartingVaultPulses() {
        XCTAssertTrue(StatusPulseRule.pulses(isRunning: false, isBooting: true, reduceMotion: false))
        XCTAssertTrue(StatusPulseRule.pulses(isRunning: true, isBooting: true, reduceMotion: false))
    }

    func testStoppedVaultIsStill() {
        XCTAssertFalse(StatusPulseRule.pulses(isRunning: false, isBooting: false, reduceMotion: false))
    }

    func testReduceMotionNeverPulses() {
        XCTAssertFalse(StatusPulseRule.pulses(isRunning: false, isBooting: true, reduceMotion: true))
    }
}
