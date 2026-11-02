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

/// List-wipe audit 2026-11-02: a follow or unfollow of a hashtag builds on
/// the newest copy across the account's own relays, never an old one that
/// answered first, and a fresh key is still asked about.
final class InterestListSaveBaseTests: XCTestCase {
    private static let own = ["wss://a.example", "wss://b.example"]
    private static func list(_ tag: String, at: Int64) -> InterestList {
        InterestList(tags: [["t", tag]], content: "", createdAt: at)
    }

    func testAnOldCopyFromOneOwnRelayIsNotTheBaseWhileAnotherIsUnheard() {
        let old = ReplaceableLookup(event: Self.list("old", at: 100), asked: 3, answered: 1,
                                    answeredBy: ["wss://a.example"], from: ["wss://a.example"])
        guard case .unknown = InterestList.saveBase(old, held: nil, own: Self.own, fresh: false) else { return XCTFail("built on A's old copy") }
        // A cached copy here doesn't stand in for the unheard relay either.
        guard case .unknown = InterestList.saveBase(old, held: Self.list("cached", at: 90), own: Self.own, fresh: false) else { return XCTFail("built on the cache") }
    }

    func testTheNewestCopyWinsOnceEveryOwnRelayAnswered() {
        let both = ReplaceableLookup(event: Self.list("new", at: 200), asked: 3, answered: 2,
                                     answeredBy: ["wss://a.example", "wss://b.example"], from: ["wss://b.example"])
        guard case .list(let base) = InterestList.saveBase(both, held: Self.list("cached", at: 100), own: Self.own, fresh: false) else { return XCTFail("no base") }
        XCTAssertEqual(base.hashtags, ["new"])
        // A newer cached copy (this device's last publish) beats an older network one.
        guard case .list(let held) = InterestList.saveBase(both, held: Self.list("mine", at: 300), own: Self.own, fresh: false) else { return XCTFail("no base") }
        XCTAssertEqual(held.hashtags, ["mine"])
    }

    func testAnEmptyCacheIsNotACopy() {
        let none = ReplaceableLookup<InterestList>(event: nil, asked: 2, answered: 2, answeredBy: Set(Self.own))
        guard case .none = InterestList.saveBase(none, held: InterestList(), own: Self.own, fresh: false) else { return XCTFail("expected none") }
    }

    func testAFreshKeyStillLosesToACopyDatedAhead() {
        let now: Int64 = 1_000_000
        let ahead = ReplaceableLookup<InterestList>(event: nil, asked: 3, answered: 1, ahead: true)
        guard case .unknown = InterestList.saveBase(ahead, held: nil, own: Self.own, fresh: true, now: now) else { return XCTFail("a list exists somewhere") }
        // Nobody answered: a fresh key builds on what it holds.
        let silent = ReplaceableLookup<InterestList>(event: nil, asked: 3, answered: 0)
        guard case .none = InterestList.saveBase(silent, held: nil, own: Self.own, fresh: true, now: now) else { return XCTFail("fresh key, nothing held") }
    }
}
