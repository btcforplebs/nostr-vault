import XCTest
@testable import MediaLogic

/// Cold start timing marks and the once-per-build templates copy
/// (Logen 2026-11-14: start up faster, Vault rows < 0.5 s).
final class StartupMarksTests: XCTestCase {
    func testLineShape() {
        XCTAssertEqual(StartupMarks.line("engine called", ms: 42), "⏱ startup engine called +42ms")
    }

    func testMillisecondsFromStart() {
        let start = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(StartupMarks.ms(since: start, now: start.addingTimeInterval(0.4567)), 457)
        XCTAssertEqual(StartupMarks.ms(since: start, now: start.addingTimeInterval(-1)), 0)
    }

    func testProcessStartIsThisProcess() {
        let ms = StartupMarks.ms(since: StartupMarks.processStart)
        XCTAssertGreaterThanOrEqual(ms, 0)
        XCTAssertLessThan(StartupMarks.processStart, Date())
        // A test run is minutes old at most, never the epoch.
        XCTAssertLessThan(ms, 3_600_000)
    }

    func testTemplatesCopiedOnlyWhenTheBuildChanged() {
        let built = Date(timeIntervalSince1970: 1_700_000_000)
        let stamp = TemplatesCopy.stamp(version: "3.2.2", build: "31", executableModified: built)
        XCTAssertEqual(stamp, "3.2.2 (31) 1700000000")
        // Same build, templates there: no copy.
        XCTAssertFalse(TemplatesCopy.needsCopy(copiedStamp: stamp + "\n", currentStamp: stamp, templatesPresent: true))
        // Update, rebuilt dev app, first launch, or templates gone: copy.
        let update = TemplatesCopy.stamp(version: "3.2.2", build: "32", executableModified: built)
        XCTAssertTrue(TemplatesCopy.needsCopy(copiedStamp: stamp, currentStamp: update, templatesPresent: true))
        let rebuilt = TemplatesCopy.stamp(version: "3.2.2", build: "31", executableModified: built.addingTimeInterval(60))
        XCTAssertTrue(TemplatesCopy.needsCopy(copiedStamp: stamp, currentStamp: rebuilt, templatesPresent: true))
        XCTAssertTrue(TemplatesCopy.needsCopy(copiedStamp: nil, currentStamp: stamp, templatesPresent: true))
        XCTAssertTrue(TemplatesCopy.needsCopy(copiedStamp: stamp, currentStamp: stamp, templatesPresent: false))
    }
}

final class LaunchStartTests: XCTestCase {
    func testStartsNowOnlyWithNothingAhead() {
        XCTAssertTrue(LaunchStart.startsNow(chainBusy: false, draining: false, meshDial: false))
        XCTAssertFalse(LaunchStart.startsNow(chainBusy: true, draining: false, meshDial: false))
        XCTAssertFalse(LaunchStart.startsNow(chainBusy: false, draining: true, meshDial: false))
        XCTAssertFalse(LaunchStart.startsNow(chainBusy: false, draining: false, meshDial: true))
    }
}
