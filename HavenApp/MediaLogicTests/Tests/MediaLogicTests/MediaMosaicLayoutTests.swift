import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import MediaLogic

/// Masonry maths for the Vault's Media tab mosaic.
final class MediaMosaicLayoutTests: XCTestCase {

    // MARK: - Shapes

    func testUnknownShapeIsSquare() {
        XCTAssertEqual(MediaMosaicLayout.clampedAspect(nil), 1)
        XCTAssertEqual(MediaMosaicLayout.clampedAspect(0), 1)
        XCTAssertEqual(MediaMosaicLayout.clampedAspect(.nan), 1)
        XCTAssertEqual(MediaMosaicLayout.clampedAspect(-2), 1)
    }

    func testExtremeShapesAreLimited() {
        XCTAssertEqual(MediaMosaicLayout.clampedAspect(10), MediaMosaicLayout.maxAspect)
        XCTAssertEqual(MediaMosaicLayout.clampedAspect(0.1), MediaMosaicLayout.minAspect)
        XCTAssertEqual(MediaMosaicLayout.clampedAspect(0.75), 0.75)
    }

    func testTileHeightFollowsShapeInWholePoints() {
        XCTAssertEqual(MediaMosaicLayout.tileHeight(columnWidth: 120, aspect: 0.75), 160)
        XCTAssertEqual(MediaMosaicLayout.tileHeight(columnWidth: 120, aspect: 4.0 / 3.0), 90)
        XCTAssertEqual(MediaMosaicLayout.tileHeight(columnWidth: 120, aspect: nil), 120)
        XCTAssertEqual(MediaMosaicLayout.tileHeight(columnWidth: 121, aspect: 16.0 / 9.0), 68)
    }

    func testColumnWidthTakesOutGaps() {
        // iPhone: 393 pt less 16 pt padding, three columns, 6 pt gaps.
        XCTAssertEqual(MediaMosaicLayout.columnWidth(forWidth: 377, columns: 3, spacing: 6), 121.666, accuracy: 0.01)
        XCTAssertEqual(MediaMosaicLayout.columnWidth(forWidth: 0, columns: 4, spacing: 8), 0)
        XCTAssertEqual(MediaMosaicLayout.columnWidth(forWidth: 100, columns: 0, spacing: 8), 100)
    }

    // MARK: - Columns

    func testFirstRowReadsLeftToRight() {
        let cols = MediaMosaicLayout.distribute(Array(0..<3), columns: 3, spacing: 6) { _ in 1 }
        XCTAssertEqual(cols, [[0], [1], [2]])
    }

    func testTallTileSendsNextItemsToShorterColumns() {
        // 0 is twice as tall as wide; 1 and 2 are wide. Column 0 is tallest,
        // so 3 goes under whichever of the others is shortest (1, leftmost tie).
        let shapes: [Double] = [0.5, 2, 2, 1, 1]
        let cols = MediaMosaicLayout.distribute(Array(0..<5), columns: 3, spacing: 6) { shapes[$0] }
        XCTAssertEqual(cols, [[0], [1, 3], [2, 4]])
    }

    func testEveryItemOnceAndOrderKeptInEachColumn() {
        let items = Array(0..<150)
        let cols = MediaMosaicLayout.distribute(items, columns: 4, spacing: 8) { Double(($0 % 5) + 1) / 3 }
        XCTAssertEqual(cols.flatMap { $0 }.sorted(), items)
        for col in cols { XCTAssertEqual(col, col.sorted()) }
    }

    func testAppendingItemsNeverMovesPlacedOnes() {
        let shape: (Int) -> Double? = { [0.75, 1.33, 1, 0.5, 1.78][$0 % 5] }
        let first = MediaMosaicLayout.distribute(Array(0..<60), columns: 3, spacing: 6, aspect: shape)
        let more = MediaMosaicLayout.distribute(Array(0..<120), columns: 3, spacing: 6, aspect: shape)
        for (a, b) in zip(first, more) { XCTAssertEqual(Array(b.prefix(a.count)), a) }
    }

    func testColumnsStayBalanced() {
        let shape: (Int) -> Double? = { [0.75, 1.33, 1, 0.5, 1.78, nil][$0 % 6] }
        let cols = MediaMosaicLayout.distribute(Array(0..<150), columns: 3, spacing: 6, aspect: shape)
        let heights = cols.map { $0.reduce(0.0) { $0 + 1 / MediaMosaicLayout.clampedAspect(shape($1)) } }
        // No column is more than one tallest tile (2 units) longer than another.
        XCTAssertLessThanOrEqual(heights.max()! - heights.min()!, 2.0)
    }

    func testOneColumnAndZeroColumnsKeepOrder() {
        XCTAssertEqual(MediaMosaicLayout.distribute([1, 2, 3], columns: 1, spacing: 8) { _ in 1 }, [[1, 2, 3]])
        XCTAssertEqual(MediaMosaicLayout.distribute([1, 2, 3], columns: 0, spacing: 8) { _ in 1 }, [[1, 2, 3]])
    }

    // MARK: - Known sizes

    private let blobHash = String(repeating: "ab", count: 32)

    func testImetaDimByURL() {
        let url = URL(string: "https://media.example/\(blobHash).jpg")!
        let tags = [["p", "x"], ["imeta", "url https://media.example/\(blobHash).jpg", "dim 3024x4032", "m image/jpeg"]]
        XCTAssertEqual(MediaMosaicLayout.aspect(tags: tags, url: url, hash: nil)!, 0.75, accuracy: 0.0001)
    }

    func testImetaDimByHashWhenShownFromAMirror() {
        let shown = URL(string: "http://127.0.0.1:3355/\(blobHash)")!
        let byX = [["imeta", "url https://other.example/file.jpg", "x \(blobHash.uppercased())", "dim 1920x1080"]]
        XCTAssertEqual(MediaMosaicLayout.aspect(tags: byX, url: shown, hash: blobHash)!, 16.0 / 9.0, accuracy: 0.0001)
        let byURL = [["imeta", "url https://blossom.example/\(blobHash).png", "dim 1000x500"]]
        XCTAssertEqual(MediaMosaicLayout.aspect(tags: byURL, url: shown, hash: blobHash)!, 2, accuracy: 0.0001)
    }

    func testImetaForAnotherFileOrBadDimIsIgnored() {
        let url = URL(string: "https://media.example/\(blobHash).jpg")!
        let other = [["imeta", "url https://media.example/other.jpg", "dim 100x400"]]
        XCTAssertNil(MediaMosaicLayout.aspect(tags: other, url: url, hash: blobHash))
        let bad = [["imeta", "url https://media.example/\(blobHash).jpg", "dim 0x400"],
                   ["imeta", "url https://media.example/\(blobHash).jpg", "dim wide"]]
        XCTAssertNil(MediaMosaicLayout.aspect(tags: bad, url: url, hash: blobHash))
        XCTAssertNil(MediaMosaicLayout.aspect(tags: nil, url: url, hash: blobHash))
    }

    func testRotatedPhotoSwapsSides() {
        XCTAssertEqual(MediaMosaicLayout.shownAspect(pixelWidth: 4032, pixelHeight: 3024, orientation: 1)!, 4.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(MediaMosaicLayout.shownAspect(pixelWidth: 4032, pixelHeight: 3024, orientation: 6)!, 0.75, accuracy: 0.0001)
        XCTAssertNil(MediaMosaicLayout.shownAspect(pixelWidth: 0, pixelHeight: 3024, orientation: 1))
    }

    func testFileHeaderShapeIsRecorded() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent(blobHash)
        let ctx = CGContext(data: nil, width: 300, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let dest = CGImageDestinationCreateWithURL(file as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))

        let sizes = MediaMosaicSizes()
        sizes.recordImageFile(file, key: blobHash)
        XCTAssertEqual(sizes.aspect(for: blobHash)!, 1.5, accuracy: 0.0001)
        sizes.recordImageFile(dir.appendingPathComponent("missing"), key: "missing")
        XCTAssertNil(sizes.aspect(for: "missing"))
    }
}
