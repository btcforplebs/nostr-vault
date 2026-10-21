import XCTest
@testable import MediaLogic

/// Generic reposts and highlights in the timelines (Logen, 2026-10-13:
/// articles and other kinds were missing from Following).
final class TimelineKindsTests: XCTestCase {
    private func json(_ object: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    func testEmbeddedArticleIsReadAsItsOwnKind() {
        let article = json(["id": "a1", "pubkey": "pk", "kind": 30023, "content": "# Title", "tags": []])
        XCTAssertEqual(GenericRepost.embeddedKind(content: article), 30023)
    }

    func testEmbeddedEventWithoutKindIsATextNote() {
        XCTAssertEqual(GenericRepost.embeddedKind(content: json(["pubkey": "pk", "content": "hi"])), 1)
    }

    func testEmptyOrPlainContentEmbedsNothing() {
        XCTAssertNil(GenericRepost.embeddedKind(content: ""))
        XCTAssertNil(GenericRepost.embeddedKind(content: "just words"))
        XCTAssertNil(GenericRepost.embeddedKind(content: json(["content": "no author"])))
    }

    func testRepostTargetPrefersEventIdThenCoordinate() {
        XCTAssertEqual(GenericRepost.target(tags: [["a", "30023:pk:slug"], ["e", "id1"]]), "id1")
        XCTAssertEqual(GenericRepost.target(tags: [["a", "30023:pk:slug"], ["k", "30023"]]), "naddr:30023:pk:slug")
        XCTAssertNil(GenericRepost.target(tags: [["p", "pk"]]))
    }

    func testHighlightSourceIsTheArticleCoordinateFirst() {
        let tags = [["e", "id1"], ["a", "30023:pk:slug"], ["r", "https://example.com/post"]]
        XCTAssertEqual(FeedHighlight.sourceReference(tags: tags), "naddr:30023:pk:slug")
        // Drawn as the quote card, so not again as a link.
        XCTAssertNil(FeedHighlight.sourceURL(tags: tags))
    }

    func testHighlightFromAWebPageShowsItsLink() {
        let tags = [["r", "https://example.com/post"], ["context", "…"]]
        XCTAssertNil(FeedHighlight.sourceReference(tags: tags))
        XCTAssertEqual(FeedHighlight.sourceURL(tags: tags)?.absoluteString, "https://example.com/post")
        XCTAssertNil(FeedHighlight.sourceURL(tags: [["r", "javascript:alert(1)"]]))
    }

    func testHighlightCommentIsTrimmedAndBlankIsNone() {
        XCTAssertEqual(FeedHighlight.comment(tags: [["comment", "  worth reading \n"]]), "worth reading")
        XCTAssertNil(FeedHighlight.comment(tags: [["comment", "   "]]))
        XCTAssertNil(FeedHighlight.comment(tags: []))
    }

    func testOnlyRepostsOfKindsWithACardAreShown() {
        XCTAssertTrue(GenericRepost.isShown(tags: [["k", "30023"]], content: ""))
        XCTAssertFalse(GenericRepost.isShown(tags: [["k", "34235"]], content: ""))
        XCTAssertFalse(GenericRepost.isShown(tags: [["k", "30311"]], content: ""))
        // The k tag wins over what is embedded.
        let video = json(["pubkey": "pk", "kind": 34235, "content": ""])
        XCTAssertFalse(GenericRepost.isShown(tags: [], content: video))
        XCTAssertTrue(GenericRepost.isShown(tags: [["k", "20"]], content: video))
        XCTAssertTrue(GenericRepost.isShown(tags: [["e", "id"]], content: ""))
    }
}
