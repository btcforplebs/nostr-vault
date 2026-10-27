import XCTest
@testable import MediaLogic

/// A link's card draws where the author wrote the link, not under the note.
final class NoteSegmentsTests: XCTestCase {
    private func url(_ s: String) -> URL { URL(string: s)! }

    func testCardSitsBetweenTheTextAroundIt() {
        let text = "Read this https://a.com/post first.\n\nThen the rest."
        XCTAssertEqual(NoteURLs.segments(text, cards: [url("https://a.com/post")]), [
            .text("Read this"), .link(url("https://a.com/post")), .text("first.\n\nThen the rest."),
        ])
    }

    func testTwoLinksKeepTheirOrderAndTheTextBetween() {
        let text = "one https://a.com two https://b.com three"
        XCTAssertEqual(NoteURLs.segments(text, cards: [url("https://a.com"), url("https://b.com")]), [
            .text("one"), .link(url("https://a.com")), .text("two"), .link(url("https://b.com")), .text("three"),
        ])
    }

    func testLinkAtStartOrEndLeavesNoEmptyText() {
        XCTAssertEqual(NoteURLs.segments("https://a.com", cards: [url("https://a.com")]), [.link(url("https://a.com"))])
        XCTAssertEqual(NoteURLs.segments("https://a.com hi\n", cards: [url("https://a.com")]), [.link(url("https://a.com")), .text("hi")])
        XCTAssertEqual(NoteURLs.segments("hi https://a.com", cards: [url("https://a.com")]), [.text("hi"), .link(url("https://a.com"))])
    }

    func testLinkWrittenTwiceGetsOneCardAtItsFirstSpot() {
        let text = "a https://a.com b https://a.com c"
        XCTAssertEqual(NoteURLs.segments(text, cards: [url("https://a.com")]), [
            .text("a"), .link(url("https://a.com")), .text("b c"),
        ])
    }

    func testLinksPastTheCapStayInTheText() {
        // a.com has a card; a.com/login is past the cap and stays text whole.
        let text = "see https://a.com and https://a.com/login"
        XCTAssertEqual(NoteURLs.segments(text, cards: [url("https://a.com")]), [
            .text("see"), .link(url("https://a.com")), .text("and https://a.com/login"),
        ])
    }

    func testTrailingPunctuationStaysWithTheText() {
        XCTAssertEqual(NoteURLs.segments("see https://x.com/a. now", cards: [url("https://x.com/a")]), [
            .text("see"), .link(url("https://x.com/a")), .text(". now"),
        ])
    }

    func testInvoiceTextIsLeftForTheFormatter() {
        // The lnbc card path cuts invoices inside each text piece; the splitter
        // must hand them through untouched.
        let invoice = "lnbc1" + String(repeating: "q", count: 120)
        let text = "pay \(invoice) or https://a.com"
        XCTAssertEqual(NoteURLs.segments(text, cards: [url("https://a.com")]), [
            .text("pay \(invoice) or"), .link(url("https://a.com")),
        ])
    }

    func testNoCardsIsOneTextPiece() {
        XCTAssertEqual(NoteURLs.segments("  just  words ", cards: []), [.text("just words")])
        XCTAssertEqual(NoteURLs.segments("   ", cards: []), [])
    }
}
