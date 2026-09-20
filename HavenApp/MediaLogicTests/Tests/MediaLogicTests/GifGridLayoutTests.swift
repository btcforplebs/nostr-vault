import XCTest
@testable import MediaLogic

/// Column maths for the GIF picker's waterfall grid.
final class GifGridLayoutTests: XCTestCase {

    // MARK: - Column count

    func testNarrowestPhoneGetsTwoColumns() {
        // 393pt iPhone less the grid's 32pt of horizontal padding.
        XCTAssertEqual(GifGridLayout.columnCount(forWidth: 361), 2)
    }

    func testAColumnIsNeverNarrowerThanTheMinimum() {
        for width in stride(from: 120.0, through: 1400.0, by: 7.0) {
            let columns = GifGridLayout.columnCount(forWidth: width)
            let columnWidth = GifGridLayout.columnWidth(forWidth: width, columns: columns)
            if columns > 1 {
                XCTAssertGreaterThanOrEqual(
                    columnWidth, GifGridLayout.minColumnWidth - 0.001,
                    "width \(width) gave \(columns) columns of \(columnWidth)pt")
            }
        }
    }

    func testColumnsAndGapsExactlyFillTheWidth() {
        let width = 508.0
        let columns = GifGridLayout.columnCount(forWidth: width)
        let columnWidth = GifGridLayout.columnWidth(forWidth: width, columns: columns)
        let used = columnWidth * Double(columns) + GifGridLayout.spacing * Double(columns - 1)
        XCTAssertEqual(used, width, accuracy: 0.001)
    }

    func testWideWindowIsCappedRatherThanShreddedIntoStamps() {
        XCTAssertEqual(GifGridLayout.columnCount(forWidth: 4000), GifGridLayout.maxColumns)
    }

    func testDegenerateWidthsStillGiveOneColumn() {
        XCTAssertEqual(GifGridLayout.columnCount(forWidth: 0), 1)
        XCTAssertEqual(GifGridLayout.columnCount(forWidth: -50), 1)
        XCTAssertEqual(GifGridLayout.columnCount(forWidth: 40), 1)
        XCTAssertEqual(GifGridLayout.columnWidth(forWidth: 300, columns: 0), 300)
    }

    // MARK: - Distribution

    func testEveryItemLandsInExactlyOneColumnInOrder() {
        let items = Array(0..<37)
        let buckets = GifGridLayout.distribute(items, columns: 3) { Double(($0 % 5) + 1) * 40 }
        XCTAssertEqual(buckets.count, 3)
        XCTAssertEqual(buckets.flatMap { $0 }.sorted(), items)
        for bucket in buckets {
            XCTAssertEqual(bucket, bucket.sorted(), "a column must keep source order")
        }
    }

    func testTheFirstItemsFillTheTopRowLeftToRight() {
        // Relevance still reads across the top before balancing takes over.
        let items = Array(0..<12)
        let buckets = GifGridLayout.distribute(items, columns: 4) { _ in 100 }
        XCTAssertEqual(buckets.map(\.first), [0, 1, 2, 3])
    }

    func testUnevenHeightsEndUpBalanced() {
        // The point of the whole thing: ragged cell heights, level columns.
        let heights: [Double] = [300, 90, 160, 240, 110, 200, 130, 175, 260, 95, 150, 220]
        let buckets = GifGridLayout.distribute(heights, columns: 3) { $0 }
        let totals = buckets.map { $0.reduce(0, +) }
        let spread = (totals.max() ?? 0) - (totals.min() ?? 0)
        // The bound greedy shortest-first actually guarantees: no column can
        // end more than one cell's height above the shortest, because that
        // cell would have gone somewhere else. Anything tighter would be a
        // number picked to match today's output.
        XCTAssertLessThan(spread, heights.max() ?? 0,
                          "columns ended \(totals), which is not a tiling")

        // And it is an improvement on dealing them round-robin, which is what
        // a row grid effectively does.
        var roundRobin = [Double](repeating: 0, count: 3)
        for (index, height) in heights.enumerated() { roundRobin[index % 3] += height }
        let rowSpread = (roundRobin.max() ?? 0) - (roundRobin.min() ?? 0)
        XCTAssertLessThan(spread, rowSpread)
    }

    func testATallItemDoesNotMonopoliseItsColumn() {
        let heights: [Double] = [1000, 100, 100, 100, 100, 100]
        let buckets = GifGridLayout.distribute(heights, columns: 2) { $0 }
        XCTAssertEqual(buckets[0], [1000])
        XCTAssertEqual(buckets[1], [100, 100, 100, 100, 100])
    }

    func testNonFiniteHeightsCannotPinEverythingToOneColumn() {
        // A GIF with a zero or bogus aspect ratio must not swallow the grid.
        let heights: [Double] = [.nan, .infinity, -50, 0, 120, 120]
        let buckets = GifGridLayout.distribute(heights, columns: 3) { $0 }
        XCTAssertEqual(buckets.flatMap { $0 }.count, 6)
        for bucket in buckets {
            XCTAssertGreaterThanOrEqual(bucket.count, 1, "no column should be left empty")
        }
    }

    func testSingleAndDegenerateColumnCounts() {
        let items = [1, 2, 3]
        XCTAssertEqual(GifGridLayout.distribute(items, columns: 1) { Double($0) }, [[1, 2, 3]])
        XCTAssertEqual(GifGridLayout.distribute(items, columns: 0) { Double($0) }, [[1, 2, 3]])
        XCTAssertEqual(GifGridLayout.distribute([Int](), columns: 3) { Double($0) }, [[], [], []])
    }
}
