import XCTest
@testable import MediaLogic

final class LocalRelaySearchPlanTests: XCTestCase {

    // MARK: Page limit

    /// The whole reason paging exists: LMDB honours a limit only up to
    /// `MaxLimit` (1500) and silently drops anything larger to `MaxLimit / 4`
    /// = 375. Asking for 2000 returns 375 events, not 2000.
    func testPageLimitNeverExceedsWhatTheRelayHonours() {
        XCTAssertLessThanOrEqual(LocalRelaySearchPlan.pageLimit,
                                 LocalRelaySearchPlan.relayMaxLimit)
        XCTAssertGreaterThan(LocalRelaySearchPlan.pageLimit, 0)
    }

    // MARK: Stepping

    func testShortPageEndsTheWalk() {
        let step = LocalRelaySearchPlan.step(received: LocalRelaySearchPlan.pageLimit - 1,
                                             newIds: 10,
                                             oldestCreatedAt: 1_700_000_000,
                                             pagesFetched: 1)
        XCTAssertEqual(step, .done)
    }

    func testEmptyPageEndsTheWalk() {
        let step = LocalRelaySearchPlan.step(received: 0,
                                             newIds: 0,
                                             oldestCreatedAt: nil,
                                             pagesFetched: 1)
        XCTAssertEqual(step, .done)
    }

    func testFullPageAsksForTheNextOneFromTheOldestTimestamp() {
        let step = LocalRelaySearchPlan.step(received: LocalRelaySearchPlan.pageLimit,
                                             newIds: 1,
                                             oldestCreatedAt: 1_699_999_999,
                                             pagesFetched: 1)
        XCTAssertEqual(step, .next(until: 1_699_999_999))
    }

    /// `until` is inclusive, so a full page whose events were all seen already
    /// means the cursor cannot move — asking again would replay it forever.
    func testFullPageOfRepeatsStopsRatherThanLooping() {
        let step = LocalRelaySearchPlan.step(received: LocalRelaySearchPlan.pageLimit,
                                             newIds: 0,
                                             oldestCreatedAt: 1_699_999_999,
                                             pagesFetched: 2)
        XCTAssertEqual(step, .done)
    }

    func testWalkIsBounded() {
        let step = LocalRelaySearchPlan.step(received: LocalRelaySearchPlan.pageLimit,
                                             newIds: LocalRelaySearchPlan.pageLimit,
                                             oldestCreatedAt: 1_699_999_999,
                                             pagesFetched: LocalRelaySearchPlan.maxPages)
        XCTAssertEqual(step, .done)
    }

    func testFullPageWithNoTimestampStops() {
        let step = LocalRelaySearchPlan.step(received: LocalRelaySearchPlan.pageLimit,
                                             newIds: 5,
                                             oldestCreatedAt: nil,
                                             pagesFetched: 1)
        XCTAssertEqual(step, .done)
    }

    // MARK: Matching

    func testQueryShorterThanTwoCharactersIsRejected() {
        XCTAssertNil(LocalSearchMatcher(query: ""))
        XCTAssertNil(LocalSearchMatcher(query: "  "))
        XCTAssertNil(LocalSearchMatcher(query: "a"))
        XCTAssertNotNil(LocalSearchMatcher(query: "ab"))
        XCTAssertNotNil(LocalSearchMatcher(query: "  ab  "))
    }

    func testNoteMatchingIsCaseInsensitiveSubstring() {
        let matcher = LocalSearchMatcher(query: "Bitcoin")!
        XCTAssertTrue(matcher.matchesNote(content: "stacking BITCOIN today"))
        XCTAssertTrue(matcher.matchesNote(content: "prebitcoiner"))
        XCTAssertFalse(matcher.matchesNote(content: "stacking sats today"))
    }

    func testProfileMatchesOnEveryDisplayedField() {
        let matcher = LocalSearchMatcher(query: "logen")!
        XCTAssertTrue(matcher.matchesProfile(displayName: "Logen", name: nil, about: nil, nip05: nil, pubkey: "abc"))
        XCTAssertTrue(matcher.matchesProfile(displayName: nil, name: "logen", about: nil, nip05: nil, pubkey: "abc"))
        XCTAssertTrue(matcher.matchesProfile(displayName: nil, name: nil, about: "shot by logen", nip05: nil, pubkey: "abc"))
        XCTAssertTrue(matcher.matchesProfile(displayName: nil, name: nil, about: nil, nip05: "logen@loge.media", pubkey: "abc"))
        XCTAssertFalse(matcher.matchesProfile(displayName: "Someone", name: "else", about: "hi", nip05: "e@x.com", pubkey: "abc"))
    }

    func testProfileMatchesOnPubkeyPrefix() {
        let matcher = LocalSearchMatcher(query: "61BF79")!
        XCTAssertTrue(matcher.matchesProfile(displayName: nil, name: nil, about: nil, nip05: nil,
                                             pubkey: "61bf790b2094afb03495c9e136acf615be0fccc2cb95b5acfb5f6ccefe18b062"))
    }

    // MARK: - A note matches on its text, and only its text

    /// Logen, 2026-09-09: searching a person's name finds the person, not
    /// everything they ever wrote. The Notes tab means "notes containing this
    /// word", and hashtags and links are derived from those notes.
    func testNoteMatchesOnItsOwnTextOnly() {
        let matcher = LocalSearchMatcher(query: "field")!
        XCTAssertTrue(matcher.matchesNote(content: "out in the FIELD today"))
        XCTAssertFalse(matcher.matchesNote(content: "gm everyone"))
    }

    /// Pins the removal: the matcher takes content and nothing else, so no
    /// caller can reintroduce an author rule by passing a set of pubkeys.
    func testMatchingANoteTakesNoAuthorInformation() {
        let matcher = LocalSearchMatcher(query: "field")!
        let rule: (String) -> Bool = matcher.matchesNote(content:)
        XCTAssertFalse(rule("gm everyone"))
    }
}
