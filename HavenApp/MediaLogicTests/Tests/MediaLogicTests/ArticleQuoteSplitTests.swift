import XCTest
@testable import MediaLogic

/// Logen 2026-11-11: an nevent, note or naddr written inside an article body
/// draws as a quote card, not as a bare `nostr:nevent1…` string.
final class ArticleQuoteSplitTests: XCTestCase {
    // Real identifiers: the Weekly Nostr Recap 101 note, and a note1 of the same id.
    private let nevent = "nevent1qqsvd857zlh6tpqhr79u84ffhs5v4d4hq7lq0mdwuszj84j6ytushygzyqk7plaq4s34lazl5nxtj3xd8uel08l46g0ul90sr7v4z6akhdevcqcyqqqqqqguslldp"
    private let hexId = "c69e9e17efa584171f8bc3d529bc28cab6b707be07edaee40523d65a22f90b91"

    func testAParagraphThatIsOnlyAQuoteBecomesACard() throws {
        let split = try XCTUnwrap(QuoteReference.articleQuoteSplit("nostr:\(nevent)"))
        XCTAssertEqual(split.text, "")
        XCTAssertEqual(split.ids, [hexId])
    }

    func testTextAroundTheQuoteStaysAndTheCardFollows() throws {
        let split = try XCTUnwrap(QuoteReference.articleQuoteSplit("Read this: nostr:\(nevent) it is good."))
        XCTAssertEqual(split.text, "Read this: it is good.")
        XCTAssertEqual(split.ids, [hexId])
    }

    func testABareReferenceAndAMarkdownLinkToOneCountToo() throws {
        XCTAssertEqual(QuoteReference.articleQuoteSplit(nevent)?.ids, [hexId])
        let linked = try XCTUnwrap(QuoteReference.articleQuoteSplit("See [the recap](nostr:\(nevent))."))
        XCTAssertEqual(linked.text, "See the recap.")
        XCTAssertEqual(linked.ids, [hexId])
    }

    func testTextWithNoQuoteIsLeftAlone() {
        XCTAssertNil(QuoteReference.articleQuoteSplit("Plain words and https://njump.me/\(nevent)"))
    }

    /// Tara (#1938): a quote in a blockquote or heading draws as a card too;
    /// the opened article no longer lists its quotes under the body.
    func testABlockquoteOrHeadingQuoteBecomesACard() {
        XCTAssertEqual(MarkdownParser.parse("> nostr:\(nevent)"), [.quotes([hexId])])
        XCTAssertEqual(MarkdownParser.parse("## Read nostr:\(nevent)"),
                       [.heading(level: 2, text: "Read"), .quotes([hexId])])
    }

    func testACodeFenceIsLeftAlone() {
        XCTAssertEqual(MarkdownParser.parse("```\nnostr:\(nevent)\n```"), [.code("nostr:\(nevent)")])
    }
}
