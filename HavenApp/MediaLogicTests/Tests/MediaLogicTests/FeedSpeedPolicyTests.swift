import XCTest
@testable import MediaLogic

/// Feed speed rules (Logen 2026-11-02, RESEARCH/NV_FEED_SPEED_AUDIT.md).
final class FeedSpeedPolicyTests: XCTestCase {

    // MARK: - Saved across relaunch

    func testOnlyDiscoverAndPopularAreKeptOnDisk() {
        XCTAssertTrue(FeedSpeedPolicy.persistsModeCache("Discovery"))
        XCTAssertTrue(FeedSpeedPolicy.persistsModeCache("Popular"))
        for mode in ["Following", "Global", "Media", "Articles", "Polls", "Recipes", "Live"] {
            XCTAssertFalse(FeedSpeedPolicy.persistsModeCache(mode), mode)
        }
    }

    func testASavedTabIsShownUpToADayTheRestFifteenMinutes() {
        XCTAssertEqual(FeedSpeedPolicy.modeCacheMaxAge(persisted: true), 24 * 3600)
        XCTAssertEqual(FeedSpeedPolicy.modeCacheMaxAge(persisted: false), 15 * 60)
    }

    func testEachAccountAndFeedHasItsOwnFile() {
        let a = FeedSpeedPolicy.diskModeCacheFileName(cacheKey: "npub1aaa|Popular")
        let b = FeedSpeedPolicy.diskModeCacheFileName(cacheKey: "npub1bbb|Popular")
        let c = FeedSpeedPolicy.diskModeCacheFileName(cacheKey: "npub1aaa|Discovery")
        XCTAssertEqual(Set([a, b, c]).count, 3)
        XCTAssertFalse(a.contains("|") || a.contains("/"))
        XCTAssertTrue(a.hasSuffix(".json"))
    }

    // MARK: - Tab switches

    func testSocketsStayOnlyBetweenTwoRelayFeeds() {
        XCTAssertTrue(FeedSpeedPolicy.keepsFeedSockets(fromStreams: true, toStreams: true))
        // To or from Popular, Music or a side feed: closed as before.
        XCTAssertFalse(FeedSpeedPolicy.keepsFeedSockets(fromStreams: true, toStreams: false))
        XCTAssertFalse(FeedSpeedPolicy.keepsFeedSockets(fromStreams: false, toStreams: true))
        XCTAssertFalse(FeedSpeedPolicy.keepsFeedSockets(fromStreams: false, toStreams: false))
    }

    // MARK: - Popular

    /// The old ranking stays up while the new one is computed, and an empty
    /// answer never wipes it.
    func testPopularKeepsTheOldRankingUnlessANewOneArrives() {
        XCTAssertTrue(FeedSpeedPolicy.popularReplacesShown(resultCount: 30, showingOld: true))
        XCTAssertFalse(FeedSpeedPolicy.popularReplacesShown(resultCount: 0, showingOld: true))
        XCTAssertTrue(FeedSpeedPolicy.popularReplacesShown(resultCount: 0, showingOld: false))
    }

    // MARK: - Loading rows

    func testLoadingRowsOnlyUntilTheFirstRelayAnswers() {
        XCTAssertTrue(FeedSpeedPolicy.showsLoadingRows(isLoading: true, hasNotes: false, relayAnswered: false))
        XCTAssertFalse(FeedSpeedPolicy.showsLoadingRows(isLoading: true, hasNotes: false, relayAnswered: true))
        XCTAssertFalse(FeedSpeedPolicy.showsLoadingRows(isLoading: true, hasNotes: true, relayAnswered: false))
        XCTAssertFalse(FeedSpeedPolicy.showsLoadingRows(isLoading: false, hasNotes: false, relayAnswered: false))
    }
}
