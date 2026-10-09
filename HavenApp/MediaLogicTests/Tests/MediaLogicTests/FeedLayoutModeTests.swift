import XCTest
@testable import MediaLogic

final class FeedLayoutModeTests: XCTestCase {

    func testCycleVisitsAllThreeOnATimeline() {
        var mode = FeedLayoutMode.expanded
        var seen: [FeedLayoutMode] = [mode]
        for _ in 0..<3 {
            mode = mode.next(supportsThreading: true)
            seen.append(mode)
        }
        XCTAssertEqual(seen, [.expanded, .condensed, .threaded, .expanded])
    }

    func testCycleSkipsThreadedWhereThreadingIsUnsupported() {
        XCTAssertEqual(FeedLayoutMode.condensed.next(supportsThreading: false), .expanded)
        XCTAssertEqual(FeedLayoutMode.expanded.next(supportsThreading: false), .condensed)
    }

    func testThreadedClampsToCondensedOnAGridFeed() {
        XCTAssertEqual(FeedLayoutMode.threaded.clamped(supportsThreading: false), .condensed)
        XCTAssertEqual(FeedLayoutMode.threaded.clamped(supportsThreading: true), .threaded)
        XCTAssertEqual(FeedLayoutMode.expanded.clamped(supportsThreading: false), .expanded)
    }

    func testBothCondensedLayoutsUseCondensedRows() {
        XCTAssertFalse(FeedLayoutMode.expanded.usesCondensedRows)
        XCTAssertTrue(FeedLayoutMode.condensed.usesCondensedRows)
        XCTAssertTrue(FeedLayoutMode.threaded.usesCondensedRows)
    }

    func testStoredLayoutWins() {
        XCTAssertEqual(
            FeedLayoutMode.resolve(storedLayout: "threaded", storedCompact: false, defaultCompact: false),
            .threaded
        )
    }

    func testLegacyCompactOverrideMigrates() {
        // Someone who had turned compact ON for this feed must not be reset.
        XCTAssertEqual(
            FeedLayoutMode.resolve(storedLayout: nil, storedCompact: true, defaultCompact: false),
            .condensed
        )
        // And someone who had turned it OFF against an ON default keeps expanded.
        XCTAssertEqual(
            FeedLayoutMode.resolve(storedLayout: nil, storedCompact: false, defaultCompact: true),
            .expanded
        )
    }

    func testFallsBackToTheFeedDefaultWhenNothingIsStored() {
        XCTAssertEqual(FeedLayoutMode.resolve(storedLayout: nil, storedCompact: nil, defaultCompact: true), .condensed)
        XCTAssertEqual(FeedLayoutMode.resolve(storedLayout: nil, storedCompact: nil, defaultCompact: false), .expanded)
    }

    func testAnUnknownStoredValueFallsBackRatherThanCrashing() {
        XCTAssertEqual(
            FeedLayoutMode.resolve(storedLayout: "galaxy-brain", storedCompact: true, defaultCompact: false),
            .condensed
        )
    }

    // MARK: - Feed picker order

    private let defaults = ["following", "global", "popular", "media", "music"]

    func testNoStoredOrderIsTheDefault() {
        XCTAssertEqual(FeedMenuOrder.visible(stored: [], hidden: [], defaults: defaults, pinned: "following"), defaults)
    }

    func testStoredOrderAndHiddenAreApplied() {
        let shown = FeedMenuOrder.visible(stored: ["media", "following", "global", "popular", "music"],
                                          hidden: ["popular"], defaults: defaults, pinned: "following")
        XCTAssertEqual(shown, ["media", "following", "global", "music"])
    }

    func testTheHomeFeedCannotBeHidden() {
        let shown = FeedMenuOrder.visible(stored: [], hidden: ["following", "global"], defaults: defaults, pinned: "following")
        XCTAssertEqual(shown, ["following", "popular", "media", "music"])
    }

    func testNewFeedsSlotInAndRemovedOnesDrop() {
        // "music" is new since the order was saved, so it goes in after
        // "media", the feed before it by default. "recipes" no longer exists.
        let shown = FeedMenuOrder.ordered(stored: ["media", "recipes", "following", "global", "popular"], defaults: defaults)
        XCTAssertEqual(shown, ["media", "music", "following", "global", "popular"])
    }

    func testEncodeRoundTrips() {
        XCTAssertEqual(FeedMenuOrder.decode(FeedMenuOrder.encode(defaults)), defaults)
        XCTAssertEqual(FeedMenuOrder.decode(""), [])
    }
}
