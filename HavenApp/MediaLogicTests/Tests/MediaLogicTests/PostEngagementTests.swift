import XCTest
@testable import MediaLogic

final class PostEngagementTests: XCTestCase {
    private let post = String(repeating: "a", count: 64)
    private let other = String(repeating: "b", count: 64)
    private let alice = String(repeating: "1", count: 64)
    private let bob = String(repeating: "2", count: 64)

    private func event(_ id: String, kind: Int, pubkey: String, tags: [[String]], content: String = "") -> [String: Any] {
        ["id": id, "kind": kind, "pubkey": pubkey, "tags": tags, "content": content]
    }

    func testCountsEachKindAgainstTheRightPost() {
        let events = [
            event("r1", kind: 7, pubkey: alice, tags: [["e", post], ["p", alice]], content: "+"),
            event("r2", kind: 7, pubkey: bob, tags: [["e", post]], content: "🔥"),
            event("s1", kind: 6, pubkey: bob, tags: [["e", post], ["p", alice]]),
            event("z1", kind: 9735, pubkey: alice, tags: [["e", post], ["bolt11", "lnbc2500u1pvjluez"]]),
            event("z2", kind: 9735, pubkey: alice, tags: [["e", post], ["bolt11", "lnbc10n1pvjluez"]]),
            event("c1", kind: 1, pubkey: bob, tags: [["e", post, "", "reply"]]),
            event("c2", kind: 1111, pubkey: alice, tags: [["E", post], ["e", post]]),
        ]
        let tally = PostEngagementQuery.tally(events, targets: [post])
        XCTAssertEqual(tally[post], PostEngagement(likes: 2, reposts: 1, replies: 2, zapSats: 250_001))
    }

    func testSameEventFromTwoRelaysCountsOnce() {
        let zap = event("z1", kind: 9735, pubkey: alice, tags: [["e", post], ["bolt11", "lnbc10n1pvjluez"]])
        XCTAssertEqual(PostEngagementQuery.tally([zap, zap], targets: [post])[post]?.zapSats, 1)
    }

    func testOnePersonReactingTwiceIsOneLike() {
        let events = [
            event("r1", kind: 7, pubkey: alice, tags: [["e", post]], content: "+"),
            event("r2", kind: 7, pubkey: alice, tags: [["e", post]], content: "🤙"),
        ]
        XCTAssertEqual(PostEngagementQuery.tally(events, targets: [post])[post]?.likes, 1)
    }

    func testDislikeIsNotALike() {
        let events = [event("r1", kind: 7, pubkey: alice, tags: [["e", post]], content: "-")]
        XCTAssertNil(PostEngagementQuery.tally(events, targets: [post])[post])
    }

    func testReactionCountsOnlyForItsLastETag() {
        // A reaction to a reply names the thread root first; it is not a like of the root.
        let events = [event("r1", kind: 7, pubkey: alice, tags: [["e", post], ["e", other]], content: "+")]
        let tally = PostEngagementQuery.tally(events, targets: [post, other])
        XCTAssertNil(tally[post])
        XCTAssertEqual(tally[other]?.likes, 1)
    }

    func testQuoteAndDeeperReplyAreNotReplies() {
        let events = [
            event("q1", kind: 1, pubkey: alice, tags: [["e", post, "", "mention"]]),
            event("d1", kind: 1, pubkey: bob, tags: [["e", post, "", "root"], ["e", other, "", "reply"]]),
        ]
        let tally = PostEngagementQuery.tally(events, targets: [post])
        XCTAssertNil(tally[post])
    }

    func testEventForAnotherPostIsIgnored() {
        let events = [event("r1", kind: 7, pubkey: alice, tags: [["e", other]], content: "+")]
        XCTAssertTrue(PostEngagementQuery.tally(events, targets: [post]).isEmpty)
    }

    func testZapWithoutReadableAmountAddsNothing() {
        let events = [event("z1", kind: 9735, pubkey: alice, tags: [["e", post], ["bolt11", "lnbc1pvjluez"]])]
        XCTAssertNil(PostEngagementQuery.tally(events, targets: [post])[post])
    }

    func testFiltersSplitIdsIntoGroups() {
        let ids = (0..<23).map { String(format: "%064d", $0) }
        let filters = PostEngagementQuery.filters(for: ids, groupSize: 10)
        XCTAssertEqual(filters.map { ($0["#e"] as? [String])?.count }, [10, 10, 3])
        XCTAssertEqual(Set(filters.flatMap { $0["#e"] as? [String] ?? [] }), Set(ids))
        XCTAssertEqual(filters.first?["kinds"] as? [Int], [7, 6, 16, 9735, 1, 1111])
    }

    func testMergeNeverShrinksANumber() {
        let shown = PostEngagement(likes: 10, reposts: 2, replies: 4, zapSats: 500)
        let short = PostEngagement(likes: 7, reposts: 3, replies: 0, zapSats: 900)
        XCTAssertEqual(shown.merged(with: short), PostEngagement(likes: 10, reposts: 3, replies: 4, zapSats: 900))
    }

    func testCompactNumbers() {
        XCTAssertEqual(PostEngagement.compact(999), "999")
        XCTAssertEqual(PostEngagement.compact(1_000), "1k")
        XCTAssertEqual(PostEngagement.compact(2_100), "2.1k")
        XCTAssertEqual(PostEngagement.compact(21_049), "21k")
        XCTAssertEqual(PostEngagement.compact(1_250_000), "1.3M")
    }
}
