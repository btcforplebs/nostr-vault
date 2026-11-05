import XCTest
@testable import MediaLogic

/// A second post, repost or delete during the countdown used to cancel the
/// first one silently.
final class PendingActionFlushTests: XCTestCase {
    func testASecondActionSendsTheFirstInsteadOfDroppingIt() {
        XCTAssertEqual(PendingActionFlush.decide(hasPending: true, queuedAccount: "aa", activeAccount: "aa"), .sendNow)
    }

    func testNothingPendingNothingToSend() {
        XCTAssertEqual(PendingActionFlush.decide(hasPending: false, queuedAccount: "aa", activeAccount: "aa"), .nothing)
    }

    func testAnActionQueuedByAnotherAccountIsNeverSentAsThisOne() {
        XCTAssertEqual(PendingActionFlush.decide(hasPending: true, queuedAccount: "aa", activeAccount: "bb"), .drop)
    }
}
