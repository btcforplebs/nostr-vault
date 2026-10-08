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

    func testRankedExtendedNetworkCountsAsTrustEvenOutsideTheGraph() {
        let sections = FollowListLogic.sections(
            people: [p("x", "Xena")], follows: [], webOfTrust: [], trustRank: ["x": 3], sort: .trusted
        )
        XCTAssertEqual(sections.first?.group, .webOfTrust)
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

    func testCountTextMarksAPartialCountWithPlus() {
        XCTAssertEqual(FollowListLogic.countText(100, more: true), "100+")
        XCTAssertEqual(FollowListLogic.countText(100, more: false), "100")
        XCTAssertEqual(FollowListLogic.countText(0, more: true), "—")
        XCTAssertEqual(FollowListLogic.countText(1_500, more: true), "1.5k+")
    }

    func testBioLineFlattensLineBreaks() {
        XCTAssertEqual(FollowListLogic.bioLine("Builder.\n\n  Bitcoin  \nnostr"), "Builder. Bitcoin nostr")
        XCTAssertNil(FollowListLogic.bioLine(" \n "))
        XCTAssertNil(FollowListLogic.bioLine(nil))
    }
}
