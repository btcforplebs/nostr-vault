import XCTest
@testable import MediaLogic

/// Follow Distance is shown in true hops: you are never a hop.
final class FollowDistanceWordsTests: XCTestCase {
    func testLevelsReadAsTrueHops() {
        XCTAssertEqual(FollowDistanceWords.short(1), "Only you")
        XCTAssertEqual(FollowDistanceWords.short(2), "1 hop")
        XCTAssertEqual(FollowDistanceWords.short(3), "2 hops")
    }

    func testReachLine() {
        XCTAssertEqual(FollowDistanceWords.reachDetail(1), "Only you. Everyone else is kept out.")
        XCTAssertEqual(FollowDistanceWords.reachDetail(2), "People within 1 hop of you. Everyone else is kept out.")
        XCTAssertEqual(FollowDistanceWords.reachDetail(3), "People within 2 hops of you. Everyone else is kept out.")
    }

    /// A level saved by an older build (0, 4, 5) reads as what the relay runs.
    func testOutOfRangeLevelsReadAsTheNearestRealOne() {
        XCTAssertEqual(FollowDistanceWords.short(0), "Only you")
        XCTAssertEqual(FollowDistanceWords.short(5), "2 hops")
    }

    /// No screen prints the raw level any more.
    func testEveryLevelTheStepperOffersHasWords() {
        for level in RelayAccessLimits.followDistance {
            XCTAssertFalse(FollowDistanceWords.short(level).contains("\(level) hop"), "level \(level) shown raw")
        }
    }
}
