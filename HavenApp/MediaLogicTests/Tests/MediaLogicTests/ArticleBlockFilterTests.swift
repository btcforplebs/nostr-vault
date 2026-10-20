import XCTest
@testable import MediaLogic

/// Blocked people's highlights and comments under an article are hidden and
/// not counted, as everywhere else a blocked person's notes would show.
final class ArticleBlockFilterTests: XCTestCase {
    private let articleId = "article1"
    private let blockedKey = "bb"
    private let friend = "ff"

    private func event(_ id: String, kind: Int, pubkey: String, content: String = "x",
                       tags: [[String]]? = nil) -> [String: Any] {
        ["id": id, "kind": kind, "pubkey": pubkey, "content": content,
         "created_at": NSNumber(value: 1_700_000_000), "tags": tags ?? [["e", articleId]]]
    }

    func testBlockedCommentIsNotShownOrCounted() {
        let events = [
            event("c1", kind: ArticleEngagement.commentKind, pubkey: blockedKey, tags: [["E", articleId], ["e", articleId]]),
            event("c2", kind: ArticleEngagement.commentKind, pubkey: friend, tags: [["E", articleId], ["e", articleId]]),
            event("r1", kind: ArticleEngagement.commentKind, pubkey: blockedKey, tags: [["E", articleId], ["e", "c2"]]),
        ]
        let tally = ArticleEngagement.tally(ArticleBlockFilter.visibleEvents(events, blocked: [blockedKey]),
                                            articleId: articleId, coordinate: nil)
        XCTAssertEqual(tally.topLevelComments.compactMap { $0["pubkey"] as? String }, [friend])
        XCTAssertEqual(tally.commentCount, 1)
        XCTAssertNil(tally.replyCounts["c2"])
    }

    func testBlockedHighlightIsNotShown() {
        let events = [
            event("h1", kind: ArticleEngagement.highlightKind, pubkey: blockedKey, content: "a passage"),
            event("h2", kind: ArticleEngagement.highlightKind, pubkey: friend, content: "another passage"),
        ]
        let shown = ArticleBlockFilter.visibleEvents(events, blocked: [blockedKey])
            .compactMap { ArticleHighlight(event: $0, articleId: articleId, coordinate: nil) }
        XCTAssertEqual(shown.map(\.pubkey), [friend])
    }

    /// Blocks are stored lowercase; a relay may send an uppercase pubkey.
    func testUppercasePubkeyStillBlocked() {
        let events = [event("l1", kind: ArticleEngagement.reactionKind, pubkey: "BB", content: "+")]
        XCTAssertTrue(ArticleBlockFilter.visibleEvents(events, blocked: [blockedKey]).isEmpty)
    }

    /// A zap receipt is signed by the Lightning provider, not the sender.
    func testZapReceiptsStay() {
        let events = [event("z1", kind: ArticleEngagement.zapReceiptKind, pubkey: blockedKey)]
        XCTAssertEqual(ArticleBlockFilter.visibleEvents(events, blocked: [blockedKey]).count, 1)
    }

    func testNothingBlockedKeepsEverything() {
        let events = [event("c1", kind: ArticleEngagement.commentKind, pubkey: blockedKey)]
        XCTAssertEqual(ArticleBlockFilter.visibleEvents(events, blocked: []).count, 1)
    }
}
