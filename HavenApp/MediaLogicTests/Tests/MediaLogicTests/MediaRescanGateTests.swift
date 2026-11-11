import XCTest
@testable import MediaLogic

final class MediaRescanGateTests: XCTestCase {
    func testFirstRequestStartsAScan() {
        var gate = MediaRescanGate()
        XCTAssertTrue(gate.request())
        XCTAssertTrue(gate.scanning)
    }

    /// The bug: a file landing mid-scan was dropped. Its request must make
    /// exactly one more scan run after the current one.
    func testRequestDuringScanRunsOneMoreScan() {
        var gate = MediaRescanGate()
        XCTAssertTrue(gate.request())
        XCTAssertFalse(gate.request())   // a file lands mid-scan
        XCTAssertFalse(gate.request())   // and another: still one rescan
        XCTAssertTrue(gate.finish())     // first scan ends: scan again
        XCTAssertTrue(gate.scanning)
        XCTAssertFalse(gate.finish())    // second ends: done
        XCTAssertFalse(gate.scanning)
    }

    func testQuietScanEndsOnce() {
        var gate = MediaRescanGate()
        XCTAssertTrue(gate.request())
        XCTAssertFalse(gate.finish())
        XCTAssertTrue(gate.request())    // next landing starts a fresh scan
    }

    func testSwappedFileIsAChange() {
        let a = URL(string: "https://localhost/aa")!
        let b = URL(string: "https://localhost/bb")!
        let c = URL(string: "https://localhost/cc")!
        XCTAssertTrue(MediaRescanGate.filesChanged(old: [a, b], new: [a, c]))
        XCTAssertTrue(MediaRescanGate.filesChanged(old: [a], new: [a, b]))
        XCTAssertFalse(MediaRescanGate.filesChanged(old: [a, b], new: [b, a]))
    }
}

final class AutoMirrorScheduleTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testOffNeverRuns() {
        XCTAssertFalse(AutoMirrorSchedule.isDue(enabled: false, lastRun: nil, now: now))
    }

    func testNeverRunIsDue() {
        XCTAssertTrue(AutoMirrorSchedule.isDue(enabled: true, lastRun: nil, now: now))
    }

    func testRecentRunWaits() {
        XCTAssertFalse(AutoMirrorSchedule.isDue(enabled: true, lastRun: now.addingTimeInterval(-60), now: now))
    }

    func testOldRunIsDue() {
        XCTAssertTrue(AutoMirrorSchedule.isDue(enabled: true, lastRun: now.addingTimeInterval(-3 * 60 * 60), now: now))
    }
}
