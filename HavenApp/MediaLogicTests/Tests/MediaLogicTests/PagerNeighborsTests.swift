import XCTest
@testable import MediaLogic

/// The full-screen photo pager preloads these pages so a swipe lands on a
/// decoded photo instead of a spinner.
final class PagerNeighborsTests: XCTestCase {
    func testMiddlePageLoadsNextThenPrevious() {
        XCTAssertEqual(PagerNeighbors.indices(around: 2, count: 5), [3, 1])
    }

    func testFirstPageHasOnlyNext() {
        XCTAssertEqual(PagerNeighbors.indices(around: 0, count: 3), [1])
    }

    func testLastPageHasOnlyPrevious() {
        XCTAssertEqual(PagerNeighbors.indices(around: 2, count: 3), [1])
    }

    func testSinglePageAndOutOfRangeHaveNone() {
        XCTAssertEqual(PagerNeighbors.indices(around: 0, count: 1), [])
        XCTAssertEqual(PagerNeighbors.indices(around: 0, count: 0), [])
        XCTAssertEqual(PagerNeighbors.indices(around: 5, count: 3), [])
        XCTAssertEqual(PagerNeighbors.indices(around: -1, count: 3), [])
    }

    func testNeighborsByValue() {
        XCTAssertEqual(PagerNeighbors.neighbors(of: "b", in: ["a", "b", "c"]), ["c", "a"])
        XCTAssertEqual(PagerNeighbors.neighbors(of: "z", in: ["a", "b", "c"]), [])
    }
}
