import XCTest
@testable import MediaLogic

/// A relay settings restart must not cut a mesh copy (2026-11-06: a fresh
/// iPad adopted its owner's relay list mid copy and the restart cancelled
/// it). It waits while the copy is on and runs once it ends.
final class MeshCopyV2RestartHoldTests: XCTestCase {
    func testNoCopyRestartsOnceQuietAndGapHavePassed() {
        XCTAssertLessThanOrEqual(MeshCopyV2.settingsRestartWait(quietLeft: -1, gapLeft: -5, copyActive: false), 0)
        XCTAssertEqual(MeshCopyV2.settingsRestartWait(quietLeft: 2, gapLeft: 7, copyActive: false), 7)
    }

    func testRunningCopyHoldsTheRestart() {
        // The 11-06 case: quiet period and gap both over, copy still building.
        let wait = MeshCopyV2.settingsRestartWait(quietLeft: -1, gapLeft: -5, copyActive: true)
        XCTAssertGreaterThan(wait, 0, "a relay-list restart would cut the running copy")
        XCTAssertEqual(wait, MeshCopyV2.restartHoldPoll)
    }

    func testRunningCopyNeverShortensALongerWait() {
        XCTAssertEqual(MeshCopyV2.settingsRestartWait(quietLeft: 1, gapLeft: 9, copyActive: true), 9)
    }

    func testRestartRunsWhenTheCopyEnds() {
        XCTAssertLessThanOrEqual(MeshCopyV2.settingsRestartWait(quietLeft: -1, gapLeft: -5, copyActive: false), 0)
    }
}
