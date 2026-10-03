import XCTest
@testable import MediaLogic

final class ArticleEngagementTests: XCTestCase {
    private let id = String(repeating: "a", count: 64)
    private let author = String(repeating: "b", count: 64)
    private let relay = "wss://relay.example"
    private let articleTags = [["d", "my-post"], ["title", "Hi"]]

    func testReactionOnArticleNamesCoordinateAndVersion() {
        let tags = ArticleEngagement.reactionTags(id: id, kind: 30023, pubkey: author, tags: articleTags, relayHint: relay)
        XCTAssertEqual(tags, [
            ["e", id, relay, author],
            ["a", "30023:\(author):my-post", relay],
            ["p", author],
            ["k", "30023"],
        ])
    }

    func testReactionOnNoteHasNoCoordinate() {
        let tags = ArticleEngagement.reactionTags(id: id, kind: 1, pubkey: author, tags: [], relayHint: relay)
        XCTAssertFalse(tags.contains { $0.first == "a" })
    }

    func testHighlightOfTrimmedPassageKeepsContextAndComment() {
        let tags = ArticleEngagement.highlightTags(id: id, kind: 30023, pubkey: author, tags: articleTags, relayHint: relay,
                                                   passage: " the good part ", context: "Before the good part after.", comment: " so true ")
        XCTAssertEqual(tags, [
            ["a", "30023:\(author):my-post", relay],
            ["e", id, relay],
            ["p", author, relay, "author"],
            ["context", "Before the good part after."],
            ["comment", "so true"],
            ["alt", "Highlight: \"the good part\""],
        ])
    }

    func testWholeParagraphHighlightDropsRedundantContextAndEmptyComment() {
        let tags = ArticleEngagement.highlightTags(id: id, kind: 30023, pubkey: author, tags: articleTags, relayHint: relay,
                                                   passage: "All of it.", context: "All of it.\n", comment: "  ")
        XCTAssertFalse(tags.contains { $0.first == "context" })
        XCTAssertFalse(tags.contains { $0.first == "comment" })
    }

    func testPlainTextStripsInlineMarkdown() {
        XCTAssertEqual(ArticleEngagement.plainText("A **bold** [link](https://x.y) word"), "A bold link word")
    }
}
