import XCTest
@testable import MediaLogic

final class OrderedMergeTests: XCTestCase {
    private struct Item: Equatable { let at: Int; let id: String }
    /// The feed's order: newest first, then id descending.
    private let newestFirst: (Item, Item) -> Bool = { $0.at != $1.at ? $0.at > $1.at : $0.id > $1.id }

    func testMergeMatchesFullSort() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let existing = (0..<Int.random(in: 0...40, using: &rng)).map { Item(at: Int.random(in: 0...20, using: &rng), id: "e\($0)") }
                .sorted(by: newestFirst)
            let batch = (0..<Int.random(in: 0...10, using: &rng)).map { Item(at: Int.random(in: 0...20, using: &rng), id: "b\($0)") }
            XCTAssertEqual(OrderedMerge.inserting(batch, into: existing, by: newestFirst),
                           (existing + batch).sorted(by: newestFirst))
        }
    }

    func testUnsortedListFallsBackToFullSort() {
        // Popular fills `notes` by score, not by time.
        let byScore = [Item(at: 1, id: "a"), Item(at: 9, id: "b"), Item(at: 5, id: "c")]
        let batch = [Item(at: 7, id: "d")]
        XCTAssertEqual(OrderedMerge.inserting(batch, into: byScore, by: newestFirst),
                       (byScore + batch).sorted(by: newestFirst))
    }

    func testEmptyBatchKeepsListAsIs() {
        let byScore = [Item(at: 1, id: "a"), Item(at: 9, id: "b")]
        XCTAssertEqual(OrderedMerge.inserting([], into: byScore, by: newestFirst), byScore)
    }
}
