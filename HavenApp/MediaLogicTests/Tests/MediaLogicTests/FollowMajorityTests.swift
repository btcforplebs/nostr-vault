import XCTest
@testable import MediaLogic

/// The follow list's save rule (Logen 2026-11-27): own write relays that
/// never connect drop out, at least two own relays must answer (indexers
/// don't count, except purplepag.es for a one-relay list), and more than
/// half of the ones that connect must answer.
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

    func testAOneRelayListAndPurplepagesBothAnsweringIsOK() {
        // Logen 2026-11-27 (b219c87b), Android #2616: a one-relay list counts
        // purplepag.es as its second relay.
        let single = [own[0]]
        XCTAssertEqual(base(lookup(answering: single, indexer: true), own: single), 100)
        XCTAssertEqual(ListMerge.followCounted(own: single), [own[0], indexer])
    }

    func testAOneRelayListWithPurplepagesSilentIsRefusedWithItsOwnReason() {
        let single = [own[0]]
        let ownOnly = lookup(answering: single)
        XCTAssertNil(base(ownOnly, own: single))
        XCTAssertEqual(FollowPublishFailure.didNotAnswer(ownOnly, own: single), .oneRelayList)
        XCTAssertEqual(FollowPublishFailure.oneRelayList.message(follow: true),
                       "Couldn't follow: your relay list has only one relay, and your newest follow list needs two of your relays to answer before it can be checked. Nothing changed. Add a relay in Settings › Relays, then try again.")
        // purplepag.es answers but the account's own relay doesn't: refused too.
        let indexerOnly = ReplaceableLookup<Int64>(event: 100, asked: 2, answered: 1, answeredBy: [indexer], from: [indexer])
        XCTAssertNil(base(indexerOnly, own: single))
        XCTAssertEqual(FollowPublishFailure.didNotAnswer(indexerOnly, own: single), .oneRelayList)
    }

    func testTwoOwnRelaysNeverCountPurplepages() {
        let two = Array(own.prefix(2))
        let one = ReplaceableLookup<Int64>(event: 100, asked: 3, answered: 2, answeredBy: [two[0], indexer],
                                           from: [two[0], indexer])
        XCTAssertNil(base(one, own: two))
        XCTAssertEqual(FollowPublishFailure.didNotAnswer(one, own: two), .tooFewAnswered(answered: 1))
        XCTAssertEqual(ListMerge.followCounted(own: two), two)
    }

    func testAOneRelayListWithNoListFoundNeedsBothAndKeepsTheShownGuard() {
        let single = [own[0]]
        let both = ReplaceableLookup<Int64>(event: nil, asked: 2, answered: 2, answeredBy: [own[0], indexer])
        let found = ListMerge.followEditBase(both, held: nil, own: single, createdAt: { $0 })
        guard case .none = found else { return XCTFail("both answered with no list: none") }
        let ownOnly = ReplaceableLookup<Int64>(event: nil, asked: 2, answered: 1, answeredBy: [own[0]])
        guard case .unknown = ListMerge.followEditBase(ownOnly, held: nil, own: single, createdAt: { $0 }) else {
            return XCTFail("purplepag.es silent: not none")
        }
        // 300 shown and none found: still refused, and not with the one-relay text (both answered).
        let shown = (0..<300).map { ["p", String(format: "%064x", $0)] }
        guard case .unknown = ListMerge.followBase(found, held: nil, before: shown,
                                                    after: shown + [["p", String(repeating: "f", count: 64)]]) else {
            return XCTFail("300 shown guard stays")
        }
        XCTAssertEqual(FollowPublishFailure.didNotAnswer(both, own: single), .relaysDidNotAnswer(ownAnswered: 2, own: 2))
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

    func testNoListAnywhereIsNotBelievedWhileTheScreenShowsPeople() {
        // Tron on #2613: 300 follows on screen (a restored snapshot), both own
        // relays answer with no list, nothing held. Building on none would
        // sign a 1-person list.
        let two = Array(own.prefix(2))
        let empty = ReplaceableLookup<Int64>(event: nil, asked: 2, answered: 2, answeredBy: Set(two))
        let found = ListMerge.followEditBase(empty, held: nil, own: two, createdAt: { $0 })
        guard case .none = found else { return XCTFail("the lookup itself says none") }
        let shown = (0..<300).map { ["p", String(format: "%064x", $0)] }
        let newPerson = ["p", String(repeating: "f", count: 64)]
        guard case .unknown = ListMerge.followBase(found, held: nil, before: shown, after: shown + [newPerson]) else {
            return XCTFail("300 shown and none found: refused, not a 1-person list")
        }
        XCTAssertEqual(FollowPublishFailure.didNotAnswer(empty, own: two), .relaysDidNotAnswer(ownAnswered: 2, own: 2))
        // An unfollow of 1 of the 300 too.
        guard case .unknown = ListMerge.followBase(found, held: nil, before: shown, after: Array(shown.dropFirst())) else {
            return XCTFail("unfollow on 300 shown and none found: refused")
        }
        // A first follow on an empty screen, or unfollowing the only person, still builds on none.
        guard case .none = ListMerge.followBase(found, held: nil, before: [], after: [newPerson]),
              case .none = ListMerge.followBase(found, held: nil, before: [newPerson], after: []) else {
            return XCTFail("nothing else on screen: none stands")
        }
        // A held signed copy wins over none anyway; followBase leaves .list alone.
        guard case .list(7) = ListMerge.followBase(EditBase<Int64>.list(7), held: nil, before: shown, after: shown + [newPerson]) else {
            return XCTFail(".list passes through")
        }
    }

    func testTheFollowTapGoesThroughFollowBase() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("HavenApp/Services/Feed/FeedService+Follow.swift")
        let src = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(src.contains("switch ListMerge.followBase(known, held: held, before: before, after: attempted)"))
    }

    func testOtherListsKeepTheOldRule() {
        let three = lookup(answering: Array(own.prefix(3)))
        guard case .unknown = ListMerge.editBase(three, held: nil, own: own, createdAt: { $0 }) else {
            return XCTFail("editBase (interests, vault lists) still counts every own relay")
        }
    }
}

private typealias EditBase = ListMerge.EditBase

private extension ListMerge.EditBase where Event == Int64 {
    var listValue: Int64? {
        if case .list(let at) = self { return at }
        return nil
    }
}
