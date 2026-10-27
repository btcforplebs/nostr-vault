import XCTest
@testable import MediaLogic

/// Adding many hashtags at once in the Hashtags feed. Mirrors Android `InterestListParseTest`.
final class InterestListParseTests: XCTestCase {
    func testSplitsOnSpacesCommasNewlinesAndHashes() {
        let parsed = InterestList.parseHashtags("#Bitcoin #nostr, art\nphotography;music #a#b")
        XCTAssertEqual(parsed.hashtags, ["bitcoin", "nostr", "art", "photography", "music", "a", "b"])
        XCTAssertEqual(parsed.rejected, [])
    }

    func testKeepsTypedOrderAndDropsRepeatsAcrossCase() {
        XCTAssertEqual(InterestList.parseHashtags("nostr #ART Nostr art").hashtags, ["nostr", "art"])
    }

    func testPiecesThatCannotBeHashtagsAreRejectedAsTyped() {
        let parsed = InterestList.parseHashtags("#123 c++ #zap_stream café 2024btc")
        XCTAssertEqual(parsed.hashtags, ["zap_stream", "café", "2024btc"])
        XCTAssertEqual(parsed.rejected, ["123", "c++"])
    }

    func testBlankInputIsNothing() {
        let parsed = InterestList.parseHashtags("  #  ,, \n")
        XCTAssertEqual(parsed.hashtags, [])
        XCTAssertEqual(parsed.rejected, [])
    }

    func testAllParsedTagsLandInOneListAndKeepTheRest() {
        let list = InterestList(tags: [["t", "art"], ["a", "30015:x:y"]], content: "secret")
        let next = InterestList.parseHashtags("#art #nostr bitcoin").hashtags
            .reduce(list) { $0.setting($1, followed: true) }
        XCTAssertEqual(next.hashtags, ["art", "nostr", "bitcoin"])
        XCTAssertEqual(next.tags[1], ["a", "30015:x:y"])
        XCTAssertEqual(next.content, "secret")
    }
}
