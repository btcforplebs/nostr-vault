import XCTest
@testable import MediaLogic

/// The feed's repost count is people, not events: the same repost arriving
/// from several relays, or again on a refresh, must not count twice.
final class RepostCountTests: XCTestCase {
    func testEachPersonCountsOncePerNote() {
        var seen = Set<String>()
        // 4 people, each repost delivered by 3 relays, then again on a refresh.
        let people = ["a", "b", "c", "d"]
        var targets: [String] = []
        for _ in 0..<6 {
            for p in people where EngagementTracker.isNewReposter(targetId: "note1", pubkey: p, seen: &seen) {
                targets.append("note1")
            }
        }
        let stats = EngagementTracker.mergeEngagementCounts(
            reactions: [], repostTargets: targets, currentStats: [:])
        XCTAssertEqual(stats["note1"]?.reposts, 4)
    }

    func testSamePersonCountsOnEachNote() {
        var seen = Set<String>()
        XCTAssertTrue(EngagementTracker.isNewReposter(targetId: "note1", pubkey: "a", seen: &seen))
        XCTAssertTrue(EngagementTracker.isNewReposter(targetId: "note2", pubkey: "a", seen: &seen))
        XCTAssertFalse(EngagementTracker.isNewReposter(targetId: "note1", pubkey: "a", seen: &seen))
    }
}
