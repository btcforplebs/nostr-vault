import XCTest
@testable import MediaLogic

/// Other people's highlights of an article: found by address and by id,
/// accepted only when they point at this article, placed on the paragraph
/// they came from.
final class ArticleHighlightTests: XCTestCase {
    private let articleId = String(repeating: "a", count: 64)
    private let coord = "30023:\(String(repeating: "b", count: 64)):my-post"

    private func event(kind: Int = 9802, content: String = "the quiet part", tags: [[String]]) -> [String: Any] {
        ["id": String(repeating: "c", count: 64), "pubkey": String(repeating: "d", count: 64),
         "kind": kind, "content": content, "created_at": 1_700_000_000, "tags": tags, "sig": ""]
    }

    func testFiltersAskByAddressAndById() {
        let filters = ArticleEngagement.highlightFilters(id: articleId, coordinate: coord)
        XCTAssertEqual(filters.count, 2)
        XCTAssertEqual(filters[0]["#a"] as? [String], [coord])
        XCTAssertEqual(filters[1]["#e"] as? [String], [articleId])
        XCTAssertTrue(filters.allSatisfy { ($0["kinds"] as? [Int]) == [9802] })
    }

    func testAHighlightByAddressCounts() {
        let h = ArticleHighlight(event: event(tags: [["a", coord], ["comment", " so true "]]), articleId: articleId, coordinate: coord)
        XCTAssertEqual(h?.passage, "the quiet part")
        XCTAssertEqual(h?.comment, "so true")
    }

    func testAHighlightByVersionIdCounts() {
        XCTAssertNotNil(ArticleHighlight(event: event(tags: [["e", articleId]]), articleId: articleId, coordinate: coord))
    }

    func testAHighlightOfSomethingElseIsRefused() {
        XCTAssertNil(ArticleHighlight(event: event(tags: [["a", "30023:x:other"]]), articleId: articleId, coordinate: coord))
        XCTAssertNil(ArticleHighlight(event: event(tags: [["e", String(repeating: "f", count: 64)]]), articleId: articleId, coordinate: coord))
    }

    func testWrongKindOrEmptyPassageIsRefused() {
        XCTAssertNil(ArticleHighlight(event: event(kind: 1, tags: [["a", coord]]), articleId: articleId, coordinate: coord))
        XCTAssertNil(ArticleHighlight(event: event(content: "  \n", tags: [["a", coord]]), articleId: articleId, coordinate: coord))
    }

    func testAPassageFindsItsParagraphDespiteCaseAndWrapping() {
        let blocks = ["Intro here.", "It was the quiet\npart, said  loudly.", "End."]
        XCTAssertEqual(ArticleEngagement.blockIndex(for: "The quiet part, said loudly", in: blocks), 1)
        XCTAssertNil(ArticleEngagement.blockIndex(for: "not in this version", in: blocks))
        XCTAssertNil(ArticleEngagement.blockIndex(for: "   ", in: blocks))
    }

    // MARK: cost caps (Tron, #189)

    private func highlight(_ n: Int, passage: String = "quiet part") -> ArticleHighlight {
        var e = event(content: passage, tags: [["a", coord]])
        e["id"] = String(format: "%064x", n)
        e["created_at"] = 1_700_000_000 + n
        return ArticleHighlight(event: e, articleId: articleId, coordinate: coord)!
    }

    func testAnOverlongPassageIsNotAHighlight() {
        let long = String(repeating: "x", count: ArticleEngagement.maxPassageLength + 1)
        XCTAssertNil(ArticleHighlight(event: event(content: long, tags: [["a", coord]]), articleId: articleId, coordinate: coord))
        let atCap = String(repeating: "x", count: ArticleEngagement.maxPassageLength)
        XCTAssertNotNil(ArticleHighlight(event: event(content: atCap, tags: [["a", coord]]), articleId: articleId, coordinate: coord))
    }

    func testFourHundredHighlightsShowTheNewestFifty() {
        let all = (0..<400).map { highlight($0) }.shuffled()
        let shown = ArticleEngagement.shown(all)
        XCTAssertEqual(shown.count, ArticleEngagement.maxShownHighlights)
        XCTAssertEqual(shown.first?.id, String(format: "%064x", 399))
        XCTAssertEqual(shown.last?.id, String(format: "%064x", 350))
    }

    func testPlacementPutsEachHighlightOnItsBlock() {
        let blocks = [(id: "p:1", text: "Intro."), (id: "p:2", text: "It was the Quiet\npart."), (id: "p:3", text: "End.")]
        let placed = ArticleEngagement.place([highlight(1), highlight(2, passage: "nowhere")], in: blocks)
        XCTAssertEqual(placed.keys.sorted(), ["p:2"])
        XCTAssertEqual(placed["p:2"]?.count, 1)
    }
}
