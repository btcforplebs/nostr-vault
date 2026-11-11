import XCTest
@testable import MediaLogic

/// A video tile shows the whole frame (Logen 11-11: thumbnails looked zoomed in).
final class VideoTileFitTests: XCTestCase {
    private let tile = CGSize(width: 120, height: 120)

    private func assertWhole(_ image: CGSize, in tile: CGSize, file: StaticString = #filePath, line: UInt = #line) {
        let d = VideoTileFit.drawnSize(image: image, in: tile)
        XCTAssertLessThanOrEqual(d.width, tile.width + 0.01, "cut left/right", file: file, line: line)
        XCTAssertLessThanOrEqual(d.height, tile.height + 0.01, "cut top/bottom", file: file, line: line)
        XCTAssertTrue(abs(d.width - tile.width) < 0.01 || abs(d.height - tile.height) < 0.01,
                      "does not reach the tile's edge", file: file, line: line)
        XCTAssertEqual(d.width / d.height, image.width / image.height, accuracy: 0.001, "shape changed", file: file, line: line)
    }

    func testPortraitVideoShowsWholeFrame() {
        assertWhole(CGSize(width: 338, height: 600), in: tile)
    }

    func testLandscapeVideoShowsWholeFrame() {
        assertWhole(CGSize(width: 600, height: 338), in: tile)
    }

    /// The diVines row: a landscape video in a 9:16 tile.
    func testLandscapeVideoInTallTileShowsWholeFrame() {
        assertWhole(CGSize(width: 600, height: 338), in: CGSize(width: 110, height: 110 * 16 / 9))
    }

    func testUnknownSizesFillTheTile() {
        XCTAssertEqual(VideoTileFit.drawnSize(image: .zero, in: tile), tile)
    }
}
