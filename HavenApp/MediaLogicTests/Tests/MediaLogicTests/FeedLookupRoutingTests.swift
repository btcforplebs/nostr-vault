import XCTest
@testable import MediaLogic

/// The quote in Nomishka's Weekly Nostr Recap 101 (2026-11-11) never loaded on
/// iOS: an naddr to a kind 30023 article with no relay hint, whose markdown has
/// 25 blank lines in a row. Its replies came back on the feed's own sockets,
/// went into the feed instead of the lookup, and the feed's spam rule dropped
/// the article (RESEARCH/NV_IOS_NADDR_QUOTE_UNAVAILABLE_2026_11_11.md).
final class FeedLookupRoutingTests: XCTestCase {

    /// The article's shape: markdown with a 25-line gap.
    private let article = "# Weekly Nostr Recap 101\n\nIntro paragraph."
        + String(repeating: "\n", count: 25)
        + "## Section two\n\nMore text, and a rule:\n\n-----\n\nEnd."

    func testEveryLookupReplyGoesToTheLookupNotTheFeed() {
        for kind in [FeedSpeedPolicy.LookupKind.notes, .address] {
            let subId = FeedSpeedPolicy.lookupSubId(kind, suffix: "AB12CD")
            XCTAssertTrue(FeedSpeedPolicy.isLookupReply(subId: subId), "\(kind) reply went to the feed")
        }
    }

    func testFeedSubscriptionsStayWithTheFeed() {
        for subId in ["feed-3-AB12CD", "m-AB12CD", "rx-AB12CD", "zaps-AB12CD", "del-AB12CD", "older-AB12CD"] {
            XCTAssertFalse(FeedSpeedPolicy.isLookupReply(subId: subId), subId)
        }
    }

    func testAnArticleIsNeverDroppedAsSpamByItsText() {
        XCTAssertFalse(FeedNote.isFeedNoise(kind: 30023, content: article, tags: [["d", "2xv8JTwpLs0S0FDIqo0XL"]]))
        // Drafts (30024) are long-form markdown too.
        XCTAssertFalse(FeedNote.isFeedNoise(kind: 30024, content: article, tags: []))
    }

    func testTheSpamRuleStillJudgesShortNotes() {
        XCTAssertTrue(FeedNote.isFeedNoise(kind: 1, content: article, tags: []))
        XCTAssertTrue(FeedNote.isFeedNoise(kind: 1, content: String(repeating: "!", count: 30), tags: []))
        XCTAssertFalse(FeedNote.isFeedNoise(kind: 1, content: "gm, a normal note", tags: []))
    }
}
