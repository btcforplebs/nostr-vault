import XCTest
@testable import MediaLogic

final class VaultSearchLogicTests: XCTestCase {

    // MARK: Sections

    func testArticlesAndMediaGetTheirOwnSections() {
        XCTAssertEqual(VaultSearchLogic.section(forKind: 30023), .articles)
        for kind in [20, 21, 22, 34235, 34236] {
            XCTAssertEqual(VaultSearchLogic.section(forKind: kind), .media, "kind \(kind)")
        }
    }

    /// Highlights, comments and polls are short text: they read as notes.
    func testEverythingElseIsANote() {
        for kind in [1, 1111, 9802, 1068] {
            XCTAssertEqual(VaultSearchLogic.section(forKind: kind), .notes, "kind \(kind)")
        }
    }

    // MARK: Hashtags

    func testHashtagsComeFromTextAndTTags() {
        let tags = VaultSearchLogic.hashtags(
            contents: [("Stacking #Bitcoin daily", []),
                       ("no hashtag in the text", [["t", "bitcoiners"], ["p", "abc"]])],
            query: "bitcoin")
        XCTAssertEqual(tags, ["bitcoin", "bitcoiners"])
    }

    /// A tag on a matched note that the query is nowhere in is not a result.
    func testHashtagsMustContainAQueryWord() {
        let tags = VaultSearchLogic.hashtags(contents: [("#coffee and #bitcoin", [])], query: "bitcoin")
        XCTAssertEqual(tags, ["bitcoin"])
    }

    func testHashInTheQueryIsIgnored() {
        let tags = VaultSearchLogic.hashtags(contents: [("#nostr", [])], query: "#nostr")
        XCTAssertEqual(tags, ["nostr"])
    }

    func testAnyQueryWordFindsATag() {
        let tags = VaultSearchLogic.hashtags(contents: [("#zapcooking #grownostr", [])], query: "zap nostr")
        XCTAssertEqual(tags, ["grownostr", "zapcooking"])
    }

    func testHashtagsAreDeduplicatedAcrossNotes() {
        let tags = VaultSearchLogic.hashtags(contents: [("#Nostr", []), ("#nostr", [["t", "Nostr"]])],
                                             query: "nostr")
        XCTAssertEqual(tags, ["nostr"])
    }

    // MARK: Links

    func testEachURLOnceInNoteOrder() {
        let links = VaultSearchLogic.links(notes: [
            ("a", "see https://example.com/one and http://example.org"),
            ("b", "again https://example.com/one"),
        ])
        XCTAssertEqual(links.map(\.url), ["https://example.com/one", "http://example.org"])
        XCTAssertEqual(links.map(\.noteId), ["a", "a"])
        XCTAssertEqual(links.first?.title, "example.com/one")
    }

    /// "…at https://x.com/y." used to keep the full stop and open a 404.
    func testSentencePunctuationIsNotPartOfTheLink() {
        let links = VaultSearchLogic.links(notes: [("a", "Read it (https://example.com/post), then https://example.com/two.")])
        XCTAssertEqual(links.map(\.url), ["https://example.com/post", "https://example.com/two"])
    }

    func testNoLinksInPlainText() {
        XCTAssertTrue(VaultSearchLogic.links(notes: [("a", "no links here")]).isEmpty)
    }
}
