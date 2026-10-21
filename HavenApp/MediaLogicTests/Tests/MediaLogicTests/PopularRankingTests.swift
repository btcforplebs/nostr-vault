import XCTest
@testable import MediaLogic

final class PopularRankingTests: XCTestCase {
    private let scores: [String: Double] = ["a": 9, "b": 5, "c": 5, "d": 4]

    func testRanksFollowShownOrder() {
        XCTAssertEqual(PopularRanking.ranks(ids: ["a", "b", "c", "d"], scores: scores),
                       ["a": 1, "b": 2, "c": 3, "d": 4])
    }

    func testFollowsOnlyRenumbersFromOne() {
        // "People you follow" drops a and c; what is left starts at #1.
        XCTAssertEqual(PopularRanking.ranks(ids: ["b", "d"], scores: scores), ["b": 1, "d": 2])
    }

    func testUnscoredRepliesTakeNoNumber() {
        XCTAssertEqual(PopularRanking.ranks(ids: ["a", "reply", "b"], scores: scores), ["a": 1, "b": 2])
    }

    func testTiesGetConsecutiveNumbers() {
        let ranks = PopularRanking.ranks(ids: ["b", "c"], scores: ["b": 5, "c": 5])
        XCTAssertEqual(Set(ranks.values), [1, 2])
    }
}
