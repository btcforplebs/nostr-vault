import XCTest
@testable import MediaLogic

final class FeedLayoutModeTests: XCTestCase {

    func testButtonTogglesExpandedAndThreaded() {
        XCTAssertEqual(FeedLayoutMode.allCases, [.expanded, .threaded], "compact view is gone")
        XCTAssertEqual(FeedLayoutMode.expanded.next(supportsThreading: true), .threaded)
        XCTAssertEqual(FeedLayoutMode.threaded.next(supportsThreading: true), .expanded)
    }

    func testFeedsThatCannotThreadStayExpanded() {
        XCTAssertEqual(FeedLayoutMode.expanded.next(supportsThreading: false), .expanded)
        XCTAssertEqual(FeedLayoutMode.threaded.clamped(supportsThreading: false), .expanded)
        XCTAssertEqual(FeedLayoutMode.threaded.clamped(supportsThreading: true), .threaded)
    }

    func testSwitchingSetsReplies() {
        XCTAssertFalse(FeedLayoutMode.expanded.showsRepliesOnSwitch, "expanded reads as single posts")
        XCTAssertTrue(FeedLayoutMode.threaded.showsRepliesOnSwitch)
    }

    func testStoredValuesReadSafely() {
        XCTAssertEqual(FeedLayoutMode(stored: "threaded"), .threaded)
        XCTAssertEqual(FeedLayoutMode(stored: "expanded"), .expanded)
        XCTAssertEqual(FeedLayoutMode(stored: "condensed"), .expanded)
        XCTAssertEqual(FeedLayoutMode(stored: "galaxy-brain"), .expanded)
        XCTAssertEqual(FeedLayoutMode(stored: nil), .expanded)
    }

    func testDecodingAnOldCondensedValueDoesNotThrow() throws {
        let decoded = try JSONDecoder().decode([FeedLayoutMode].self, from: Data(#"["condensed","threaded"]"#.utf8))
        XCTAssertEqual(decoded, [.expanded, .threaded])
        let encoded = String(decoding: try JSONEncoder().encode([FeedLayoutMode.threaded]), as: UTF8.self)
        XCTAssertEqual(encoded, #"["threaded"]"#)
    }

    func testCompactChoicesMigrateToExpanded() {
        let result = FeedLayoutMode.migrateCompact(
            layouts: ["Global": "condensed", "Following": "threaded"],
            legacyCompact: ["Global": true, "Following": true, "Popular": true, "Catch Up": false]
        )
        XCTAssertTrue(result.hadCompact)
        XCTAssertEqual(result.layouts, ["Global": "expanded", "Following": "threaded", "Popular": "expanded"],
                       "a saved layout beats the legacy switch; legacy compact with no layout becomes expanded")
    }

    func testNothingCompactLeavesConfigAndRepliesAlone() {
        let result = FeedLayoutMode.migrateCompact(
            layouts: ["Global": "expanded", "Following": "threaded"],
            legacyCompact: ["Following": true, "Global": false]
        )
        XCTAssertFalse(result.hadCompact)
        XCTAssertEqual(result.layouts, ["Global": "expanded", "Following": "threaded"])
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
