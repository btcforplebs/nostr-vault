import XCTest
@testable import MediaLogic

final class ProfilePostsLoadPlanTests: XCTestCase {
    func testNoRelayListAsksTheBigPublicRelays() {
        XCTAssertEqual(
            ProfilePostsLoadPlan.fallbackRelays(writeRelays: nil, asked: []),
            ["wss://nos.lol", "wss://relay.primal.net", "wss://relay.snort.social"])
    }

    func testListWithNoWriteRelaysCountsAsNoList() {
        XCTAssertEqual(ProfilePostsLoadPlan.fallbackRelays(writeRelays: [], asked: []).count, 3)
    }

    func testKnownWriteRelaysNeedNoFallback() {
        XCTAssertEqual(
            ProfilePostsLoadPlan.fallbackRelays(writeRelays: ["wss://relay.example.com"], asked: []),
            [])
    }

    func testFallbackSkipsRelaysAlreadyAskedInAnySpelling() {
        let asked: Set<String> = [ProfilePostsLoadPlan.relayKey("wss://Relay.Primal.net/")]
        XCTAssertEqual(
            ProfilePostsLoadPlan.fallbackRelays(writeRelays: nil, asked: asked),
            ["wss://nos.lol", "wss://relay.snort.social"])
    }

    func testEmptyLoadWithASilentRelayRetriesOnce() {
        XCTAssertTrue(ProfilePostsLoadPlan.shouldRetry(postsFound: 0, alreadyRetried: false, everyRelayFinished: false))
        XCTAssertFalse(ProfilePostsLoadPlan.shouldRetry(postsFound: 0, alreadyRetried: true, everyRelayFinished: false))
        XCTAssertFalse(ProfilePostsLoadPlan.shouldRetry(postsFound: 1, alreadyRetried: false, everyRelayFinished: false))
    }

    /// Sweep 11-01 #5: every relay sent EOSE with nothing, so the profile has
    /// no posts. A second load only held "Loading…" for up to 36 s.
    func testEmptyLoadEveryRelayFinishedDoesNotRetry() {
        XCTAssertFalse(ProfilePostsLoadPlan.shouldRetry(postsFound: 0, alreadyRetried: false, everyRelayFinished: true))
    }

    /// The relay list lookup must outlast fetchRelayList's own 10 s window,
    /// and a late relay gets a full answer window of its own.
    func testTimeoutsCoverTheLookup() {
        XCTAssertGreaterThanOrEqual(ProfilePostsLoadPlan.relayListTimeout, 10)
        XCTAssertGreaterThanOrEqual(ProfilePostsLoadPlan.relayAnswerTimeout, 8)
    }
}
