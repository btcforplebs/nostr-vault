import XCTest
@testable import MediaLogic

/// Column maths for the media grids that lay themselves out from the width
/// they are given (b21 iPad parity). The counts the phone draws today are the
/// floor: this suite is what keeps the iPad work from moving the phone.
final class AdaptiveGridLayoutTests: XCTestCase {

    /// The profile and Vault media grids: three across on a phone, up to six.
    private func mediaColumns(_ width: Double) -> Int {
        AdaptiveGridLayout.columnCount(forWidth: width, ideal: 180, spacing: 6,
                                       minimum: 3, maximum: 6)
    }

    // MARK: - The phone does not move

    func testUnmeasuredWidthKeepsThePhoneCount() {
        // 0 is "not measured yet", and every non-iPad platform, which passes 0
        // on purpose. The grid must draw three, not one.
        XCTAssertEqual(mediaColumns(0), 3)
    }

    func testNarrowWidthsNeverDropBelowTheMinimum() {
        // 393pt iPhone, 320pt SE, and a 280pt iPad split-view column: a tile
        // narrower than ideal is accepted before a count below the phone's.
        for width in [320.0, 361.0, 377.0, 280.0, 1.0] {
            XCTAssertEqual(mediaColumns(width), 3, "width \(width)")
        }
    }

    // MARK: - The iPad uses its width

    func testIPadPortraitAndLandscapeGainColumns() {
        // iPad 11in portrait (834 - 16 of grid padding) and landscape (1194 - 16).
        XCTAssertEqual(mediaColumns(818), 4)
        XCTAssertEqual(mediaColumns(1178), 6)
    }

    func testTheMaximumIsACap() {
        // A 13in iPad in landscape would otherwise draw seven postage stamps.
        XCTAssertEqual(mediaColumns(1350), 6)
        XCTAssertEqual(mediaColumns(4000), 6)
    }

    // MARK: - The maths itself

    func testATileIsNeverNarrowerThanIdealOncePastTheMinimum() {
        for width in stride(from: 200.0, through: 2000.0, by: 7.0) {
            let columns = mediaColumns(width)
            guard columns > 3 else { continue }
            let tile = AdaptiveGridLayout.tileWidth(forWidth: width, columns: columns, spacing: 6)
            XCTAssertGreaterThanOrEqual(tile, 180 - 0.001,
                                        "width \(width) gave \(columns) columns of \(tile)pt")
        }
    }

    func testTilesAndGapsExactlyFillTheWidth() {
        let width = 1178.0
        let columns = mediaColumns(width)
        let tile = AdaptiveGridLayout.tileWidth(forWidth: width, columns: columns, spacing: 6)
        let used = tile * Double(columns) + 6 * Double(columns - 1)
        XCTAssertEqual(used, width, accuracy: 0.001)
    }

    func testCountRisesWithWidthAndNeverFalls() {
        var last = mediaColumns(0)
        for width in stride(from: 100.0, through: 3000.0, by: 3.0) {
            let columns = mediaColumns(width)
            XCTAssertGreaterThanOrEqual(columns, last, "width \(width) went backwards")
            last = columns
        }
    }

    func testAnUpsideDownRangeFallsBackToTheMinimum() {
        XCTAssertEqual(AdaptiveGridLayout.columnCount(forWidth: 1200, ideal: 180, spacing: 6,
                                                      minimum: 4, maximum: 2), 4)
        XCTAssertEqual(AdaptiveGridLayout.columnCount(forWidth: 1200, ideal: 0, spacing: 6,
                                                      minimum: 3, maximum: 6), 3)
    }
}
