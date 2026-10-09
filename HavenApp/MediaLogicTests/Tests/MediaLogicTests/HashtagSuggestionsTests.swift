import XCTest
@testable import MediaLogic

final class HashtagSuggestionsTests: XCTestCase {
    func testMostUsedFirstAndCaseMerged() {
        let notes: [[[String]]] = [
            [["t", "Bitcoin"], ["t", "art"]],
            [["t", "bitcoin"]],
            [["t", "#BITCOIN"], ["p", "abc"]],
            [["t", "art"]],
            [["t", "music"]],
        ]
        XCTAssertEqual(HashtagSuggestions.top(notes, excluding: []), ["bitcoin", "art", "music"])
    }

    func testCountsATagOncePerNote() {
        let notes: [[[String]]] = [
            [["t", "art"], ["t", "Art"], ["t", "art"]],
            [["t", "music"]],
            [["t", "music"]],
        ]
        XCTAssertEqual(HashtagSuggestions.top(notes, excluding: []), ["music", "art"])
    }

    func testExcludesFollowedTags() {
        let notes: [[[String]]] = [[["t", "nostr"]], [["t", "art"]]]
        XCTAssertEqual(HashtagSuggestions.top(notes, excluding: ["Nostr"]), ["art"])
    }

    func testCapAndAlphabeticalTies() {
        let notes: [[[String]]] = ["d", "c", "b", "a"].map { [["t", $0]] }
        XCTAssertEqual(HashtagSuggestions.top(notes, excluding: [], limit: 3), ["a", "b", "c"])
    }

    func testIgnoresMalformedAndEmptyTags() {
        let notes: [[[String]]] = [[["t"], ["t", ""], ["t", " # "]]]
        XCTAssertEqual(HashtagSuggestions.top(notes, excluding: []), [])
    }
}
