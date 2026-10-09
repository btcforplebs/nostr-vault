import XCTest
@testable import MediaLogic

final class InterestListTests: XCTestCase {
    func testFollowAddsLowercaseTagAndKeepsOtherTags() {
        let list = InterestList(tags: [["t", "bitcoin"], ["a", "30015:abc:music"]], content: "secret", createdAt: 10)
        let next = list.setting("#Nostr", followed: true)
        XCTAssertEqual(next.tags, [["t", "bitcoin"], ["a", "30015:abc:music"], ["t", "nostr"]])
        XCTAssertEqual(next.content, "secret")
        XCTAssertEqual(next.hashtags, ["bitcoin", "nostr"])
    }

    func testFollowIsIdempotentAcrossCase() {
        let list = InterestList(tags: [["t", "Bitcoin"]])
        XCTAssertEqual(list.setting("bitcoin", followed: true), list)
        XCTAssertTrue(list.contains("BITCOIN"))
    }

    func testUnfollowRemovesEveryCaseVariantOnly() {
        let list = InterestList(tags: [["t", "Bitcoin"], ["t", "bitcoin"], ["t", "art"], ["a", "30015:x:y"]])
        let next = list.setting("bitcoin", followed: false)
        XCTAssertEqual(next.tags, [["t", "art"], ["a", "30015:x:y"]])
    }

    func testEmptyNameIsIgnored() {
        let list = InterestList(tags: [["t", "art"]])
        XCTAssertEqual(list.setting(" # ", followed: true), list)
        XCTAssertEqual(list.setting("", followed: false), list)
    }

    func testHashtagsSkipsMalformedAndDuplicateTags() {
        let list = InterestList(tags: [["t"], ["t", ""], ["t", "Art"], ["t", "art"], ["p", "abc"]])
        XCTAssertEqual(list.hashtags, ["art"])
    }
}
