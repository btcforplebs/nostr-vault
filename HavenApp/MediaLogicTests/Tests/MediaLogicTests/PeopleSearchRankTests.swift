import XCTest
@testable import MediaLogic

/// The shared people order (search plan §1a, A3).
final class PeopleSearchRankTests: XCTestCase {
    private func key(_ n: Int) -> String { String(format: "%064x", n) }
    private typealias P = PeopleSearchRank.Person

    private func rank(_ people: [P], _ query: String, _ circle: PeopleSearchRank.Circle,
                      blocked: Set<String> = [], keepUnmatched: Bool = false, limit: Int? = nil) -> [String] {
        PeopleSearchRank.rank(people, query: query, circle: circle, blocked: blocked,
                              keepUnmatched: keepUnmatched, limit: limit, person: { $0 }).map(\.pubkey)
    }

    private func copy(_ people: [String: TrustRankCopy.Person]) -> TrustRankCopy {
        TrustRankCopy(account: key(0), builtAt: 1, maxHop: 6, viewBar: 55, floor: 0, people: people)
    }

    // MARK: Closeness

    func testYouThenFollowsThenWebThenFurtherThenOutside() {
        let people = (1...5).map { P(pubkey: key($0), name: "alice") }
        let circle = PeopleSearchRank.Circle(own: [key(5)], follows: [key(4)], web: [key(3)],
                                             copy: copy([key(2): .init(score: 40, hop: 3)]))
        XCTAssertEqual(rank(people, "alice", circle), [key(5), key(4), key(3), key(2), key(1)])
    }

    /// Logen 5d1ce4cb #6: 3+ steps away is inside your web.
    func testThreeStepsAwayIsInside() {
        let circle = PeopleSearchRank.Circle(own: [], follows: [], web: [],
                                             copy: copy([key(1): .init(score: 10, hop: 4),
                                                         key(2): .init(score: 10, hop: 2)]))
        XCTAssertTrue(PeopleSearchRank.isInside(key(1), in: circle))
        XCTAssertEqual(PeopleSearchRank.tier(key(1), in: circle), PeopleSearchRank.Tier.further)
        XCTAssertEqual(PeopleSearchRank.tier(key(2), in: circle), PeopleSearchRank.Tier.web)
        XCTAssertFalse(PeopleSearchRank.isInside(key(3), in: circle))
    }

    func testThreadPeopleComeFirstWhenGiven() {
        let people = [P(pubkey: key(1), name: "bob"), P(pubkey: key(2), name: "bobby")]
        let circle = PeopleSearchRank.Circle(own: [], follows: [key(1)], web: [], thread: [key(2)])
        XCTAssertEqual(rank(people, "bob", circle), [key(2), key(1)])
    }

    // MARK: Name match

    func testExactThenPrefixThenWordThenContainsThenAbout() {
        let people = [
            P(pubkey: key(1), about: "I like alice"),
            P(pubkey: key(2), name: "Malice"),
            P(pubkey: key(3), displayName: "Big Alice"),
            P(pubkey: key(4), name: "alicewebber"),
            P(pubkey: key(5), displayName: "ALICE"),
        ]
        let circle = PeopleSearchRank.Circle(own: [], follows: [], web: [])
        XCTAssertEqual(rank(people, " alice ", circle), [key(5), key(4), key(3), key(2), key(1)])
    }

    func testAccentsAndCaseFold() {
        let people = [P(pubkey: key(1), name: "Zoëy"), P(pubkey: key(2), name: "zoe")]
        let circle = PeopleSearchRank.Circle(own: [], follows: [], web: [])
        XCTAssertEqual(rank(people, "ZOE", circle), [key(2), key(1)])
    }

    func testNip05LocalPartIsAName() {
        let people = [P(pubkey: key(1), name: "jack dorsey"), P(pubkey: key(2), nip05: "jack@cash.app")]
        let circle = PeopleSearchRank.Circle(own: [], follows: [], web: [])
        XCTAssertEqual(rank(people, "jack", circle), [key(2), key(1)])
        XCTAssertEqual(P(pubkey: key(3), nip05: "_@example.com").names, ["_@example.com"])
    }

    /// Closeness beats the name: an exact name outside never jumps a follow.
    func testCloserPrefixBeatsFartherExact() {
        let people = [P(pubkey: key(1), name: "dan"), P(pubkey: key(2), name: "daniel")]
        let circle = PeopleSearchRank.Circle(own: [], follows: [key(2)], web: [])
        XCTAssertEqual(rank(people, "dan", circle), [key(2), key(1)])
    }

    // MARK: Ties

    func testTrustScoreThenShorterNameThenKey() {
        let people = [
            P(pubkey: key(3), name: "carolyn"),
            P(pubkey: key(2), name: "carol two"),
            P(pubkey: key(1), name: "carol one"),
            P(pubkey: key(4), name: "carolina"),
        ]
        let circle = PeopleSearchRank.Circle(own: [], follows: [], web: [],
                                             copy: copy([key(4): .init(score: 90, hop: 3),
                                                         key(3): .init(score: 50, hop: 3),
                                                         key(2): .init(score: 50, hop: 3),
                                                         key(1): .init(score: 50, hop: 3)]))
        // 4 scores highest; 3 is the shortest of the 50s; 1 before 2 by key.
        XCTAssertEqual(rank(people, "car", circle), [key(4), key(3), key(1), key(2)])
    }

    // MARK: Filtering

    func testBlockedAreDroppedAndEachKeyOnce() {
        let people = [P(pubkey: key(1), name: "eve"), P(pubkey: key(2), name: "eve"),
                      P(pubkey: key(2).uppercased(), name: "eve")]
        let circle = PeopleSearchRank.Circle(own: [], follows: [], web: [])
        XCTAssertEqual(rank(people, "eve", circle, blocked: [key(1)]), [key(2)])
    }

    func testUnmatchedAreDroppedUnlessKept() {
        let people = [P(pubkey: key(1), name: "frank"), P(pubkey: key(2), name: "relay hit")]
        let circle = PeopleSearchRank.Circle(own: [], follows: [key(2)], web: [])
        XCTAssertEqual(rank(people, "fra", circle), [key(1)])
        // A relay's own match stays, last in its tier: here a follow, so first.
        XCTAssertEqual(rank(people, "fra", circle, keepUnmatched: true), [key(2), key(1)])
        XCTAssertTrue(rank(people, "  ", circle).isEmpty)
    }

    func testLimit() {
        let people = (1...5).map { P(pubkey: key($0), name: "gus\($0)") }
        let circle = PeopleSearchRank.Circle(own: [], follows: [], web: [])
        XCTAssertEqual(rank(people, "gus", circle, limit: 2).count, 2)
    }

    // MARK: Outside fold

    /// Logen 5d1ce4cb #1: an exact name outside your web stays in the fold.
    func testExactNameOutsideStaysInTheFold() {
        let people = [P(pubkey: key(1), name: "henry"), P(pubkey: key(2), name: "henry the cat")]
        let circle = PeopleSearchRank.Circle(own: [], follows: [key(2)], web: [])
        let split = PeopleSearchRank.split(people, query: "henry", circle: circle, person: { $0 })
        XCTAssertEqual(split.inside.map(\.pubkey), [key(2)])
        XCTAssertEqual(split.outside.map(\.pubkey), [key(1)])
        XCTAssertTrue(PeopleSearchRank.outsideHoldsTheOnlyExactMatch(
            inside: split.inside, outside: split.outside, query: "Henry", person: { $0 }))
    }

    func testFoldStaysShutWhenAnExactMatchIsInside() {
        let people = [P(pubkey: key(1), name: "ivy"), P(pubkey: key(2), name: "Ivy")]
        let circle = PeopleSearchRank.Circle(own: [], follows: [key(2)], web: [])
        let split = PeopleSearchRank.split(people, query: "ivy", circle: circle, person: { $0 })
        XCTAssertFalse(PeopleSearchRank.outsideHoldsTheOnlyExactMatch(
            inside: split.inside, outside: split.outside, query: "ivy", person: { $0 }))
    }

    // MARK: Notes share the tiers

    func testNotesFoldUsesTheSameInside() {
        let distant = key(9)
        let split = GlobalSearchRanking.splitOutside([key(1), distant], own: [], follows: [], wot: [],
                                                     distant: { $0 == distant }, pubkey: { $0 })
        XCTAssertEqual(split.inside, [distant])
        XCTAssertEqual(split.outside, [key(1)])
        XCTAssertEqual(GlobalSearchRanking.tier(pubkey: distant, own: [], follows: [], wot: [],
                                                distant: { $0 == distant }), 3)
        XCTAssertEqual(GlobalSearchRanking.tier(pubkey: key(1), own: [], follows: [], wot: []),
                       GlobalSearchRanking.outsideTier)
    }
}
