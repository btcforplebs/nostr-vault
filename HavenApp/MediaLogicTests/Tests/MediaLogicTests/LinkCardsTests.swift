import XCTest
@testable import MediaLogic

/// A note's links each get a card that fetches the page; a spam note with
/// hundreds of links must not become hundreds of requests from the phone.
final class LinkCardsTests: XCTestCase {
    func testHundredsOfLinksGetThreeCards() {
        let links = (1...500).map { URL(string: "https://attacker.example/p\($0)")! }
        XCTAssertEqual(LinkCards.shown(links), Array(links.prefix(3)))
    }

    func testFewerLinksThanTheCapAreAllShown() {
        let links = [URL(string: "https://a.com/x")!, URL(string: "https://b.com/y")!]
        XCTAssertEqual(LinkCards.shown(links), links)
    }
}

/// Removing the links that got cards must not cut into the ones that did not.
final class NoteURLsStripTests: XCTestCase {
    private func url(_ s: String) -> URL { URL(string: s)! }

    func testAShownLinkInsideAKeptLinkLeavesTheKeptLinkWhole() {
        // Tron's case: with the cap, a.com gets a card and leaves the text,
        // while a.com/login stays. A substring replace left "/login".
        let text = "a https://a.com b https://b.com c https://c.com read https://a.com/login"
        let shown = LinkCards.shown(NoteURLs.cardRegex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range, in: text).map { url(String(text[$0])) } })
        XCTAssertEqual(shown.count, 3)
        XCTAssertEqual(NoteURLs.strip(shown, from: text), "a b c read https://a.com/login")
    }

    func testAShownLinkInsideAKeptLinksQueryIsLeftAlone() {
        let text = "https://a.com and https://b.com/?r=https://a.com"
        XCTAssertEqual(NoteURLs.strip([url("https://a.com")], from: text), "and https://b.com/?r=https://a.com")
    }

    func testTrailingPunctuationAndGapsAsBefore() {
        XCTAssertEqual(NoteURLs.strip([url("https://x.com/a")], from: "see https://x.com/a. now"), "see . now")
        XCTAssertEqual(NoteURLs.strip([url("https://x.com/a")], from: "https://x.com/a"), "")
    }

    /// The cards come from `cardRegex`, so a URL written right after "(" or
    /// "[" gets one; the strip must match it whole there too (Tron, #184).
    func testAShownLinkInBracketsLeavesTheKeptLinkWhole() {
        for text in ["(https://a.com) https://b.com https://c.com read https://a.com/login",
                     "[https://a.com] https://b.com https://c.com read https://a.com/login"] {
            let shown = LinkCards.shown(NoteURLs.cardRegex.matches(in: text, range: NSRange(text.startIndex..., in: text))
                .compactMap { Range($0.range, in: text).map { url(String(text[$0])) } })
            XCTAssertEqual(shown.map(\.absoluteString), ["https://a.com", "https://b.com", "https://c.com"])
            XCTAssertTrue(NoteURLs.strip(shown, from: text).hasSuffix("read https://a.com/login"), text)
        }
    }

    func testMediaInParenthesesIsStillStripped() {
        XCTAssertEqual(NoteURLs.strip([url("https://x.com/p.jpg")], from: "pic (https://x.com/p.jpg)"), "pic ()")
    }
}
