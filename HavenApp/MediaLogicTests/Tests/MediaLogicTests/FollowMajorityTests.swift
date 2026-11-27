import XCTest
@testable import MediaLogic

/// The follow list's save rule (Logen 2026-11-27): own write relays that
/// never connect drop out, at least two own relays must answer (indexers
/// don't count), and more than half of the ones that connect must answer.
/// Web (followListKnown) and Android (FollowListKnown, #2612) test the same cases.
final class FollowMajorityTests: XCTestCase {
    private let own = (1...7).map { "wss://r\($0).example" }
    private let indexer = "wss://purplepag.es"

    /// A lookup where `answering` own relays answered, `slow` more were
    /// reached (or not dialled, or timed out) but sent nothing in time, and
    /// the rest of the 7 were dialled and failed to connect.
    private func lookup(answering: [String], slow: [String] = [], indexer: Bool = false,
                        event: Int64? = 100) -> ReplaceableLookup<Int64> {
        let answeredBy = Set(answering + (indexer ? [self.indexer] : []))
        let dead = Set(own).subtracting(answering).subtracting(slow)
        return ReplaceableLookup(event: answeredBy.isEmpty ? nil : event, asked: own.count + 1, answered: answeredBy.count,
                                 answeredBy: answeredBy, from: event == nil ? [] : answeredBy, unreachable: dead)
    }

    private func base(_ lookup: ReplaceableLookup<Int64>, own: [String]? = nil) -> Int64? {
        if case .list(let at) = ListMerge.followEditBase(lookup, held: nil, own: own ?? self.own, createdAt: { $0 }) { return at }
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
                       "Couldn't follow: only 1 of your relays answered, and it takes 2 of them to check your newest follow list. Nothing changed. Try again in a moment.")
    }

    func testOneOwnRelayAndAnIndexerIsRefused() {
        // purplepag.es is not the account's relay: it can't be the second answer.
        let withIndexer = lookup(answering: [own[0]], indexer: true)
        XCTAssertNil(base(withIndexer))
        XCTAssertEqual(FollowPublishFailure.didNotAnswer(withIndexer, own: own), .tooFewAnswered(answered: 1))
        XCTAssertTrue(ListMerge.ownMajority(ownAnswered: 1, own: 1, answered: 2), "the old rule let one own relay and an indexer through")
    }

    func testAOneRelayListIsRefusedWithItsOwnReason() {
        let single = [own[0]]
        let both = lookup(answering: single, indexer: true)
        XCTAssertNil(base(both, own: single))
        XCTAssertEqual(FollowPublishFailure.didNotAnswer(both, own: single), .oneRelayList)
        XCTAssertEqual(FollowPublishFailure.oneRelayList.message(follow: true),
                       "Couldn't follow: your relay list has only one relay, and your newest follow list needs two of your relays to answer before it can be checked. Nothing changed. Add a relay in Settings › Relays, then try again.")
    }

    func testZeroAnsweringIsRefused() {
        let none = lookup(answering: [], slow: Array(own.prefix(2)))
        XCTAssertNil(base(none))
        XCTAssertEqual(FollowPublishFailure.didNotAnswer(none, own: own), .tooFewAnswered(answered: 0))
        XCTAssertEqual(FollowPublishFailure.tooFewAnswered(answered: 0).message(follow: false),
                       "Couldn't unfollow: none of your relays answered, so your newest follow list can't be checked. Nothing changed. Check your connection, then try again.")
    }

    func testASlowButConnectedRelayStillCounts() {
        // 4 never connect, 3 connect: two answer and one is slow, so 2 of 3.
        XCTAssertEqual(base(lookup(answering: Array(own.prefix(2)), slow: [own[2]])), 100)
        XCTAssertFalse(ListMerge.ownMajority(ownAnswered: 2, own: 7, answered: 2), "the old rule refused this")
        // 5 connect, two answer and three are slow: 2 of 5 is not most.
        // Dropping slow relays would say yes (2 of 2).
        let slow = lookup(answering: Array(own.prefix(2)), slow: Array(own[2..<5]))
        XCTAssertNil(base(slow))
        XCTAssertEqual(FollowPublishFailure.didNotAnswer(slow, own: own), .relaysDidNotAnswer(ownAnswered: 2, own: 7))
    }

    func testARelayNotDialledOrTimedOutStillCounts() {
        // Tron on web #2611: 4 own relays, 2 answer with a stale list, and the
        // other 2 hold the newer one but were cooling down / over the socket
        // cap / hit the connect timeout. They are not "never connected", so
        // 2 of 4 is not most and the stale list is not edited.
        let four = Array(own.prefix(4))
        var notDialled = lookup(answering: Array(four.prefix(2)), slow: Array(four.suffix(2)))
        XCTAssertNil(ListMerge.followEditBase(notDialled, held: nil, own: four, createdAt: { $0 }).listValue)
        // Only a dial that really failed to connect drops out: then 2 of 2.
        notDialled = ReplaceableLookup(event: 100, asked: 4, answered: 2, answeredBy: Set(four.prefix(2)),
                                       from: Set(four.prefix(2)), unreachable: Set(four.suffix(2)))
        XCTAssertEqual(ListMerge.followEditBase(notDialled, held: nil, own: four, createdAt: { $0 }).listValue, 100)
    }

    func testAFirstFollowWithNoListFoundStillNeedsEveryOwnRelay() {
        // Tron on web #2611: 2 empty relays answer, the list holder is
        // unreachable. "No list" would let a 1-follow list replace 300.
        let three = Array(own.prefix(3))
        let empty = ReplaceableLookup<Int64>(event: nil, asked: 3, answered: 2, answeredBy: Set(three.prefix(2)),
                                             unreachable: [three[2]])
        guard case .unknown = ListMerge.followEditBase(empty, held: nil, own: three, createdAt: { $0 }) else {
            return XCTFail("no list found needs every own relay, dead ones included")
        }
        let all = ReplaceableLookup<Int64>(event: nil, asked: 3, answered: 3, answeredBy: Set(three))
        guard case .none = ListMerge.followEditBase(all, held: nil, own: three, createdAt: { $0 }) else {
            return XCTFail("every own relay answered with no list: none")
        }
    }

    func testOtherListsKeepTheOldRule() {
        let three = lookup(answering: Array(own.prefix(3)))
        guard case .unknown = ListMerge.editBase(three, held: nil, own: own, createdAt: { $0 }) else {
            return XCTFail("editBase (interests, vault lists) still counts every own relay")
        }
    }
}

private extension ListMerge.EditBase where Event == Int64 {
    var listValue: Int64? {
        if case .list(let at) = self { return at }
        return nil
    }
}
