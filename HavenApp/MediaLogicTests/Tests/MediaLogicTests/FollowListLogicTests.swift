import XCTest
@testable import MediaLogic

final class FollowListLogicTests: XCTestCase {

    private func p(_ key: String, _ name: String, _ recency: Int64 = 0, nip05: String = "") -> FollowListPerson {
        FollowListPerson(pubkey: key, name: name, nip05: nip05, recency: recency)
    }

    func testGroupsInOrderFollowsThenTrustThenOutsideAndDropEmpty() {
        let people = [p("o", "Oscar"), p("w", "Wren"), p("f", "Fay")]
        let sections = FollowListLogic.sections(
            people: people, follows: ["f"], webOfTrust: ["w", "f"], trustRank: [:], sort: .name
        )
        XCTAssertEqual(sections.map(\.group), [.follows, .webOfTrust, .outside])
        XCTAssertEqual(sections.map { $0.people.map(\.pubkey) }, [["f"], ["w"], ["o"]])

        let onlyOutside = FollowListLogic.sections(
            people: [p("o", "Oscar")], follows: [], webOfTrust: [], trustRank: [:], sort: .name
        )
        XCTAssertEqual(onlyOutside.map(\.group), [.outside])
    }

    /// Audit fix 5 (11-27): the group is the gate's inside set only. A rank
    /// in the extended network orders rows; it does not let anyone in.
    func testRankedExtendedNetworkOutsideTheGateStaysOutside() {
        let sections = FollowListLogic.sections(
            people: [p("x", "Xena")], follows: [], webOfTrust: [], trustRank: ["x": 3], sort: .trusted
        )
        XCTAssertEqual(sections.first?.group, .outside)
    }

    func testSpamIsHiddenAndDuplicatesCollapse() {
        let sections = FollowListLogic.sections(
            people: [p("s", "Spam"), p("a", "Ann"), p("a", "Ann")],
            follows: [], webOfTrust: [], trustRank: [:], hidden: ["s"], sort: .name
        )
        XCTAssertEqual(sections.flatMap { $0.people.map(\.pubkey) }, ["a"])
    }

    func testMostTrustedPutsRankedFirstThenNewest() {
        let people = [p("old", "Old", 1), p("new", "New", 9), p("r2", "R2", 0), p("r1", "R1", 0)]
        let ordered = FollowListLogic.ordered(people, by: .trusted, trustRank: ["r1": 0, "r2": 5])
        XCTAssertEqual(ordered.map(\.pubkey), ["r1", "r2", "new", "old"])
    }

    func testRecentAndNameOrders() {
        let people = [p("a", "bob", 2), p("b", "Alice", 1), p("c", "carl", 3)]
        XCTAssertEqual(FollowListLogic.ordered(people, by: .recent, trustRank: [:]).map(\.pubkey), ["c", "a", "b"])
        XCTAssertEqual(FollowListLogic.ordered(people, by: .name, trustRank: [:]).map(\.pubkey), ["b", "a", "c"])
    }

    func testSearchMatchesNameOrNip05CaseInsensitively() {
        let people = [p("a", "Jack", nip05: "jack@cash.app"), p("b", "Odell", nip05: "odell@primal.net")]
        let hits = FollowListLogic.sections(
            people: people, follows: [], webOfTrust: [], trustRank: [:], sort: .name, query: " PRIMAL "
        )
        XCTAssertEqual(hits.flatMap { $0.people.map(\.pubkey) }, ["b"])
    }

    /// Search plan A6: a typed name puts exact, then prefix, matches first in
    /// each group; the picked sort holds within each part; groups stay.
    func testQueryMatchesFirstWithinEachGroup() {
        let people = [p("a", "Big Dan", 9), p("b", "Daniel", 5), p("c", "dan", 1),
                      p("d", "Danny", 8), p("e", "Jordan", 7, nip05: "dan@x.com")]
        let sections = FollowListLogic.sections(
            people: people, follows: ["a", "b", "c"], webOfTrust: [], trustRank: [:], sort: .recent, query: "Dan"
        )
        XCTAssertEqual(sections.map(\.group), [.follows, .outside])
        // Follows: "dan" exact; "Daniel" prefix; "Big Dan" only a word.
        XCTAssertEqual(sections[0].people.map(\.pubkey), ["c", "b", "a"])
        // Outside: Jordan's NIP-05 local part is exactly "dan"; Danny a prefix.
        XCTAssertEqual(sections[1].people.map(\.pubkey), ["e", "d"])
    }

    func testNoQueryKeepsThePickedSort() {
        let people = [p("a", "Dan", 1), p("b", "Daniel", 5)]
        XCTAssertEqual(FollowListLogic.queryMatchesFirst(people, query: " ").map(\.pubkey), ["a", "b"])
        XCTAssertEqual(FollowListLogic.queryMatchesFirst(people, query: "dani").map(\.pubkey), ["b", "a"])
    }

    func testCountTextMarksAPartialCountWithPlus() {
        XCTAssertEqual(FollowListLogic.countText(100, more: true), "100+")
        XCTAssertEqual(FollowListLogic.countText(100, more: false), "100")
        XCTAssertEqual(FollowListLogic.countText(0, more: true), "—")
        XCTAssertEqual(FollowListLogic.countText(1_500, more: true), "1.5k+")
    }

    func testBlockedPeopleAreDroppedFromBothListsAndTheirCounts() {
        let spam: Set<String> = ["bot"]
        let blocked: Set<String> = ["blocked"]
        let dropped = FollowListLogic.dropped(spam: spam, blocked: blocked)
        let people = [p("friend", "Friend"), p("blocked", "Blocked"), p("bot", "Bot")]
        let shown = FollowListLogic.sections(
            people: people, follows: [], webOfTrust: [], trustRank: [:], hidden: dropped, sort: .name
        )
        XCTAssertEqual(shown.flatMap { $0.people.map(\.pubkey) }, ["friend"])
        XCTAssertEqual(FollowListLogic.shownCount(["friend", "blocked", "bot"], dropped: dropped), 1)

        // The control: with nobody blocked, spam alone is hidden and the
        // count still includes everyone else.
        let spamOnly = FollowListLogic.dropped(spam: spam, blocked: [])
        let withBlocked = FollowListLogic.sections(
            people: people, follows: [], webOfTrust: [], trustRank: [:], hidden: spamOnly, sort: .name
        )
        XCTAssertEqual(withBlocked.flatMap { $0.people.map(\.pubkey) }, ["blocked", "friend"])
        XCTAssertEqual(FollowListLogic.shownCount(["friend", "blocked", "bot"], dropped: spamOnly), 2)
        XCTAssertEqual(FollowListLogic.shownCount(["friend", "blocked"], dropped: []), 2)
    }

    func testBioLineFlattensLineBreaks() {
        XCTAssertEqual(FollowListLogic.bioLine("Builder.\n\n  Bitcoin  \nnostr"), "Builder. Bitcoin nostr")
        XCTAssertNil(FollowListLogic.bioLine(" \n "))
        XCTAssertNil(FollowListLogic.bioLine(nil))
    }
}
