import XCTest
@testable import MediaLogic

final class FeedFilterBadgeTests: XCTestCase {

    /// Following as a fresh install has it: nothing changed.
    private var followingDefaults: FeedFilterBadge {
        FeedFilterBadge(autoLoad: false, reposts: true, replies: true)
    }

    func testDefaultsMatchAFreshInstall() {
        let config = HavenConfig()
        XCTAssertEqual(FeedFilterBadge.defaultAutoLoad, config.autoLoadNewPosts)
        XCTAssertEqual(FeedFilterBadge.defaultReposts, config.showReposts)
        XCTAssertEqual(FeedFilterBadge.defaultReplies, config.showReplies)
        XCTAssertEqual(FeedFilterBadge.defaultEveryone, config.globalShowsEveryone)
    }

    func testFreshFollowingCountsNothing() {
        XCTAssertEqual(followingDefaults.count, 0)
        XCTAssertEqual(followingDefaults.accessibilityLabel, "Filter")
    }

    func testEachChangedToggleCountsOnce() {
        var badge = followingDefaults
        badge.autoLoad = true
        XCTAssertEqual(badge.count, 1)
        badge.reposts = false
        XCTAssertEqual(badge.count, 2)
        badge.replies = false
        XCTAssertEqual(badge.count, 3)
        XCTAssertEqual(badge.accessibilityLabel, "Filter, 3 changed")
    }

    func testSettingsAFeedDoesNotHaveNeverCount() {
        // Global has no replies toggle: hidden replies elsewhere must not show here.
        let global = FeedFilterBadge(everyone: false, languageCount: 0, autoLoad: false, reposts: true)
        XCTAssertEqual(global.count, 0)
        XCTAssertEqual(FeedFilterBadge().count, 0)
    }

    func testGlobalCountsEveryoneAndLanguages() {
        let global = FeedFilterBadge(everyone: true, languageCount: 2, autoLoad: false, reposts: true)
        XCTAssertEqual(global.count, 2)
    }

    func testPollsCountsGlobalScopeAndNarrowedStatus() {
        var polls = FeedFilterBadge(followingScope: true, autoLoad: false, pollStatusNarrowed: false)
        XCTAssertEqual(polls.count, 0)
        polls.followingScope = false
        polls.pollStatusNarrowed = true
        XCTAssertEqual(polls.count, 2)
    }

    func testScopeCountsAgainstTheFeedsOwnDefault() {
        let opensGlobal = FeedFilterBadge(followingScope: false, defaultFollowingScope: false)
        XCTAssertEqual(opensGlobal.count, 0)
        XCTAssertEqual(FeedFilterBadge(followingScope: true, defaultFollowingScope: false).count, 1)
    }

    func testPopularCountsAudienceAndRanks() {
        XCTAssertEqual(FeedFilterBadge(popularNarrowed: true, ranks: true).count, 2)
        XCTAssertEqual(FeedFilterBadge(popularNarrowed: false, ranks: false).count, 0)
    }
}
