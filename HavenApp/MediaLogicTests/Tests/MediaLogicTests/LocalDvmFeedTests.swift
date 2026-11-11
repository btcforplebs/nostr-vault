import XCTest
@testable import MediaLogic

final class LocalDvmFeedTests: XCTestCase {
    private let a = String(repeating: "a", count: 64)
    private let b = String(repeating: "b", count: 64)

    func testFollowsJSONIsSortedLowercaseHexOnly() {
        let json = LocalDvmFeed.followsJSON([b, a.uppercased(), a, "npub1xyz", ""])
        XCTAssertEqual(json, "[\"\(a)\",\"\(b)\"]")
        XCTAssertEqual(LocalDvmFeed.followsJSON([]), "[]")
    }

    func testOnlyCatchUpSkipsTheTrustGraph() {
        XCTAssertFalse(LocalDvmFeed.catchUp.needsTrustGraph)
        XCTAssertTrue(LocalDvmFeed.popular.needsTrustGraph)
        XCTAssertTrue(LocalDvmFeed.underrated.needsTrustGraph)
    }

    /// FeedMode maps onto these by raw value: a rename on one side would
    /// silently drop the feed from the local DVM path.
    func testRawValuesMatchTheFeedPicker() {
        XCTAssertEqual(LocalDvmFeed.allCases.map(\.rawValue), ["Popular", "Catch Up", "Underrated"])
    }
    /// Logen 2026-11-11: Underrated ran out onto the background.
    func testEndOfListOnlyOnALoadedLocalDvmFeedWithNotes() {
        XCTAssertTrue(LocalDvmFeed.showsEndOfList(mode: .underrated, hasNotes: true, isLoading: false))
        XCTAssertFalse(LocalDvmFeed.showsEndOfList(mode: nil, hasNotes: true, isLoading: false), "Home, Articles, Global")
        XCTAssertFalse(LocalDvmFeed.showsEndOfList(mode: .popular, hasNotes: false, isLoading: false), "empty state owns it")
        XCTAssertFalse(LocalDvmFeed.showsEndOfList(mode: .catchUp, hasNotes: true, isLoading: true))
    }

    func testEndOfListCopyIsPerFeed() {
        XCTAssertEqual(LocalDvmFeed.underrated.endOfListStatus + " Pull to refresh.",
                       "That's today's underrated list. Pull to refresh.")
        XCTAssertEqual(Set(LocalDvmFeed.allCases.map(\.endOfListStatus)).count, 3)
    }

    // MARK: Underrated's empty state (haven-go underratedEmptyReason)

    func testUnderratedReasonIsReadFromTheRelaysEmptyAnswer() {
        XCTAssertEqual(UnderratedEmptyReason.parse(#"{"reason":"web_incomplete"}"#), .webIncomplete)
        XCTAssertEqual(UnderratedEmptyReason.parse(#"{"reason":"nothing_qualified"}"#), .nothingQualified)
        XCTAssertEqual(UnderratedEmptyReason.parse(#"{"reason":"web_not_ready"}"#), .webNotReady)
        // A list of notes, an error, or a reason this build doesn't know: none.
        XCTAssertNil(UnderratedEmptyReason.parse(#"[{"id":"x"}]"#))
        XCTAssertNil(UnderratedEmptyReason.parse("[]"))
        XCTAssertNil(UnderratedEmptyReason.parse(#"{"error":"relay not running"}"#))
        XCTAssertNil(UnderratedEmptyReason.parse(#"{"reason":"something_new"}"#))
    }

    /// Logen 2026-11-11: a follows-only web offered Refresh, which cannot
    /// help. web_incomplete offers Build your wider network; everything else
    /// keeps Refresh Feed.
    func testUnderratedEmptyStatePicksTheButtonFromTheReason() {
        let incomplete = UnderratedEmptyState.of(reason: .webIncomplete, building: false)
        XCTAssertEqual(incomplete.title, "Underrated needs your wider web")
        XCTAssertEqual(incomplete.action, .buildWiderNetwork)
        XCTAssertFalse(incomplete.subtitle.contains("Check back later"))

        for reason in [UnderratedEmptyReason.nothingQualified, .webNotReady, nil] {
            let state = UnderratedEmptyState.of(reason: reason, building: false)
            XCTAssertEqual(state.action, .refreshFeed, "\(String(describing: reason))")
            XCTAssertEqual(state.title, "Nothing underrated yet")
        }

        // While the job runs the button says so and can't be tapped again.
        XCTAssertEqual(UnderratedEmptyState.of(reason: .webIncomplete, building: true).action, .buildingWiderNetwork)
        XCTAssertEqual(UnderratedEmptyState.of(reason: nil, building: true).action, .buildingWiderNetwork)
    }
}
