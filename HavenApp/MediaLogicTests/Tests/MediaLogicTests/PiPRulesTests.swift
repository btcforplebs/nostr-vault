import XCTest
@testable import MediaLogic

/// PiP on the live stream from the mini player, feed videos and Mac (RESEARCH/NV_PIP_PLAN.md lane B).
final class PiPRulesTests: XCTestCase {
    func testClosingPiPLeavesTheMiniPlayersStreamPlaying() {
        XCTAssertTrue(PiPRules.pausesWhenClosed(sharedPlayback: false), "our own video stops and hands audio back")
        XCTAssertFalse(PiPRules.pausesWhenClosed(sharedPlayback: true), "the mini player's live stream keeps its sound")
    }

    func testButtonShowsWheneverTheDeviceCanDoPiP() {
        XCTAssertTrue(PiPRules.showsButton(supported: true))
        XCTAssertFalse(PiPRules.showsButton(supported: false))
    }
}
