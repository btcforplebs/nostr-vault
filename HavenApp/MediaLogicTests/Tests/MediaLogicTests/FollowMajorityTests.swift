import XCTest
@testable import MediaLogic

/// The follow list's save rule (Logen 2026-11-27): own write relays that
/// never connect drop out, more than half of the ones that do connect must
/// answer, and at least two relays must answer in all. Web and Android
/// (followMajority) are tested on the same cases.
final class FollowMajorityTests: XCTestCase {
    private let own = (1...7).map { "wss://r\($0).example" }
    private let indexer = "wss://purplepag.es"

    /// A lookup where `answering` own relays answered, `slow` more connected
    /// but sent nothing in time, and the rest of the 7 never connected.
    private func lookup(answering: [String], slow: [String] = [], indexer: Bool = false) -> ReplaceableLookup<Int64> {
        let answeredBy = Set(answering + (indexer ? [self.indexer] : []))
        return ReplaceableLookup(event: answeredBy.isEmpty ? nil : 100 as Int64, asked: own.count + 1, answered: answeredBy.count,
                                 answeredBy: answeredBy, from: answeredBy, reached: answeredBy.union(slow))
    }

    private func base(_ lookup: ReplaceableLookup<Int64>) -> Int64? {
        if case .list(let at) = ListMerge.followEditBase(lookup, held: nil, own: own, createdAt: { $0 }) { return at }
        return nil
    }

    func testThreeOfSevenDeadAndFourAnswerIsEnough() {
        XCTAssertEqual(base(lookup(answering: Array(own.prefix(4)))), 100)
    }

    func testFourOfSevenDeadAndThreeAnswerIsEnough() {
        // rd 2026-11-27: four dead relays in the 10002 blocked every follow.
        XCTAssertEqual(base(lookup(answering: Array(own.prefix(3)))), 100)
        XCTAssertFalse(ListMerge.ownMajority(ownAnswered: 3, own: 7, answered: 3), "the old rule refused this")
    }

    func testOneAnsweringIsRefused() {
        let one = lookup(answering: [own[0]])
        XCTAssertNil(base(one))
        XCTAssertEqual(FollowPublishFailure.didNotAnswer(one, own: own), .tooFewAnswered(answered: 1))
        XCTAssertEqual(FollowPublishFailure.tooFewAnswered(answered: 1).message(follow: true),
                       "Couldn't follow: only 1 relay answered, and it takes 2 to check your newest follow list. Nothing changed. Try again in a moment.")
    }

    func testZeroAnsweringIsRefused() {
        let none = lookup(answering: [], slow: Array(own.prefix(2)))
        XCTAssertNil(base(none))
        XCTAssertEqual(FollowPublishFailure.didNotAnswer(none, own: own), .tooFewAnswered(answered: 0))
        XCTAssertEqual(FollowPublishFailure.tooFewAnswered(answered: 0).message(follow: false),
                       "Couldn't unfollow: no relay answered, so your newest follow list can't be checked. Nothing changed. Check your connection, then try again.")
    }

    func testASlowButConnectedRelayStillCounts() {
        // 4 never connect, 3 connect: two answer and one is slow, so 2 of 3.
        XCTAssertEqual(base(lookup(answering: Array(own.prefix(2)), slow: [own[2]])), 100)
        XCTAssertFalse(ListMerge.ownMajority(ownAnswered: 2, own: 7, answered: 2), "the old rule refused this")
        // 3 connect, one answers and two are slow: 1 of 3 is not most, even
        // with an indexer making two answers. Dropping slow relays would say yes.
        let slow = lookup(answering: [own[0]], slow: [own[1], own[2]], indexer: true)
        XCTAssertNil(base(slow))
        XCTAssertEqual(FollowPublishFailure.didNotAnswer(slow, own: own), .relaysDidNotAnswer(ownAnswered: 1, own: 7))
    }

    func testOneOwnRelayAndAnIndexerIsStillEnough() {
        XCTAssertEqual(base(lookup(answering: [own[0]], indexer: true)), 100)
    }

    func testOtherListsKeepTheOldRule() {
        let three = lookup(answering: Array(own.prefix(3)))
        guard case .unknown = ListMerge.editBase(three, held: nil, own: own, createdAt: { $0 }) else {
            return XCTFail("editBase (interests, vault lists) still counts every own relay")
        }
    }
}
