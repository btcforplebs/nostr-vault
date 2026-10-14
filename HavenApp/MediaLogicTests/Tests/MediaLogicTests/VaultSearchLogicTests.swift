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

    /// Tron on #641: Wikipedia-style links end in ")" and were cut to a
    /// dead "…/Bitcoin_(currency". A paren the URL opened stays; one that
    /// closes the sentence around it still goes.
    func testAClosingParenTheURLOpenedStays() {
        let links = VaultSearchLogic.links(notes: [("a", """
            https://en.wikipedia.org/wiki/Bitcoin_(currency) and \
            (see https://en.wikipedia.org/wiki/Nostr_(protocol)). \
            [https://example.com/x[1]]
            """)])
        XCTAssertEqual(links.map(\.url), [
            "https://en.wikipedia.org/wiki/Bitcoin_(currency)",
            "https://en.wikipedia.org/wiki/Nostr_(protocol)",
            "https://example.com/x[1]",
        ])
    }

    func testNoLinksInPlainText() {
        XCTAssertTrue(VaultSearchLogic.links(notes: [("a", "no links here")]).isEmpty)
    }

    // MARK: People

    private let jackNpub = "npub1sg6plzptd64u62a878hep2kev88swjh3tw00gjsfl8f237lmu63q0uf63m"
    private let jackHex = "82341f882b6eabcd2ba7f1ef90aad961cf074af15b9ef44a09f9d2a8fbfbe6a2"

    func testAPastedKeyNamesItsPerson() {
        XCTAssertEqual(VaultSearchLogic.pubkey(inQuery: jackHex), jackHex)
        XCTAssertEqual(VaultSearchLogic.pubkey(inQuery: " \(jackHex.uppercased()) "), jackHex)
        XCTAssertEqual(VaultSearchLogic.pubkey(inQuery: jackNpub), jackHex)
        XCTAssertEqual(VaultSearchLogic.pubkey(inQuery: "nostr:\(jackNpub)"), jackHex)
        XCTAssertNil(VaultSearchLogic.pubkey(inQuery: String(jackHex.dropLast())))
        XCTAssertNil(VaultSearchLogic.pubkey(inQuery: "jack"))
    }

    /// A hex key typed into search finds that profile, and only that one.
    func testAHexKeyFindsThatProfile() {
        let noName: [String?] = [nil, nil, nil, nil]
        XCTAssertTrue(VaultSearchLogic.keepsPerson(pubkey: jackHex, fields: noName, query: jackHex))
        XCTAssertTrue(VaultSearchLogic.keepsPerson(pubkey: jackHex, fields: noName, query: jackNpub))
        let other = String(repeating: "ab", count: 32)
        XCTAssertFalse(VaultSearchLogic.keepsPerson(pubkey: other, fields: ["jack", nil, nil, nil], query: jackHex))
    }

    /// Tron on #641: a short query matched inside the hex key, so "ab"
    /// listed nearly every profile. Only names, about and NIP-05 count.
    func testAShortQueryDoesNotMatchInsideTheKey() {
        XCTAssertFalse(VaultSearchLogic.keepsPerson(pubkey: jackHex, fields: ["Jack", "jack", nil, nil], query: "abcd"))
        XCTAssertTrue(VaultSearchLogic.keepsPerson(pubkey: jackHex, fields: ["Jack", "jack", nil, nil], query: "jack"))
        XCTAssertTrue(VaultSearchLogic.keepsPerson(pubkey: jackHex, fields: [nil, nil, nil, "jack@cash.app"], query: "cash"))
    }

    // MARK: Query state

    /// Tron's repro on #641: "ab" lands, "abc" starts, the field goes back
    /// to "ab" while "abc" is walking. The spinner must not stay up.
    func testBackToTheShownQueryDoesNotLeaveTheSpinnerUp() {
        var state = VaultSearchLogic.QueryState()
        XCTAssertEqual(state.typed("ab"), .run("ab"))
        XCTAssertTrue(state.started("ab"))
        XCTAssertTrue(state.landed("ab", as: .done))

        XCTAssertEqual(state.typed("abc"), .run("abc"))
        XCTAssertTrue(state.started("abc"))
        XCTAssertEqual(state.status, .searching)

        XCTAssertEqual(state.typed("ab"), .keep)
        XCTAssertEqual(state.status, .done)
        XCTAssertEqual(state.resultsQuery, "ab")

        // "abc" finishes late: it is for a query no longer in the field.
        XCTAssertFalse(state.landed("abc", as: .done))
        XCTAssertEqual(state.status, .done)
        XCTAssertEqual(state.resultsQuery, "ab")
    }

    /// The same, but "ab" had never landed: it runs again, and its answer
    /// is the one that counts.
    func testALateAnswerForAnOldQueryIsDropped() {
        var state = VaultSearchLogic.QueryState()
        _ = state.typed("ab"); _ = state.started("ab")
        XCTAssertEqual(state.typed("abc"), .run("abc"))
        _ = state.started("abc")
        XCTAssertEqual(state.typed("ab"), .run("ab"))
        _ = state.started("ab")
        XCTAssertFalse(state.landed("abc", as: .done))
        XCTAssertEqual(state.status, .searching)
        XCTAssertTrue(state.landed("ab", as: .done))
        XCTAssertEqual(state.status, .done)
    }

    /// A search whose debounce outlived the field's text never starts.
    func testAStaleSearchDoesNotStart() {
        var state = VaultSearchLogic.QueryState()
        _ = state.typed("ab")
        _ = state.typed("abc")
        XCTAssertFalse(state.started("ab"))
        XCTAssertEqual(state.status, .idle)
    }

    func testUnderTwoCharactersClears() {
        var state = VaultSearchLogic.QueryState()
        _ = state.typed("ab"); _ = state.started("ab"); _ = state.landed("ab", as: .done)
        XCTAssertEqual(state.typed(" a "), .clear)
        XCTAssertEqual(state.status, .idle)
        XCTAssertEqual(state.resultsQuery, "")
    }

    /// In-memory and cut-short answers are partial: the same query asks again.
    func testPartialAnswersAreAskedAgain() {
        for partial in [VaultSearchLogic.Status.inMemory, .cutShort] {
            var state = VaultSearchLogic.QueryState()
            _ = state.typed("ab"); _ = state.started("ab"); _ = state.landed("ab", as: partial)
            XCTAssertEqual(state.typed("ab "), .run("ab"), "\(partial)")
        }
    }
}
