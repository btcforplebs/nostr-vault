import XCTest
@testable import MediaLogic

/// The discovery feed's author set is this ranking truncated to 500, so the
/// order has to be total: an arbitrary tie-break means a different feed every
/// time the same data is recomputed.
final class ExtendedNetworkRankingTests: XCTestCase {

    func testRanksByMutualFollowCountDescending() {
        let ranked = ContactManager.rankExtendedNetwork(
            mutualCounts: ["a": 1, "b": 5, "c": 3]
        )
        XCTAssertEqual(ranked, ["b", "c", "a"])
    }

    /// The bug: most of the second hop ties at one or two mutuals, so the cut
    /// lands inside a tie group. Ties must resolve the same way every time.
    func testTiesBreakOnPubkeySoTheOrderIsTotal() {
        let counts = ["ccc": 2, "aaa": 2, "bbb": 2]
        XCTAssertEqual(ContactManager.rankExtendedNetwork(mutualCounts: counts), ["aaa", "bbb", "ccc"])
    }

    /// The shape the real data has: a big block of people tied at one mutual
    /// follow, truncated in the middle. Who survives the cut has to be decided
    /// by the tie-break, not by whatever order the dictionary happened to be in.
    func testTheCutLineInsideATieGroupIsDecidedByTheTieBreak() {
        let counts = Dictionary(uniqueKeysWithValues: (0..<100).map { (String(format: "pk%03d", $0), 1) })
        let ranked = ContactManager.rankExtendedNetwork(mutualCounts: counts, maxResults: 10)
        XCTAssertEqual(ranked, (0..<10).map { String(format: "pk%03d", $0) })
    }

    func testTruncatesToMaxResults() {
        let counts = Dictionary(uniqueKeysWithValues: (0..<10).map { ("pk\($0)", 10 - $0) })
        XCTAssertEqual(ContactManager.rankExtendedNetwork(mutualCounts: counts, maxResults: 3).count, 3)
    }

    func testEmptyCountsRankToNothing() {
        XCTAssertTrue(ContactManager.rankExtendedNetwork(mutualCounts: [:]).isEmpty)
    }

    // MARK: - countMutualFollows

    func testCountsOnePerPTagAndExcludesYourOwnFollows() {
        let tags = [["p", "alice"], ["p", "bob"], ["e", "note"], ["p"]]
        XCTAssertEqual(
            ContactManager.countMutualFollows(eventTags: tags, excludeSet: ["bob"]),
            ["alice": 1]
        )
    }
}
