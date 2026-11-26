import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import MediaLogic

final class ImageCompressorTests: XCTestCase {
    // MARK: - Rules

    private func plan(_ type: UTType, _ w: Int, _ h: Int, bytes: Int = 5_000_000, frames: Int = 1,
                      alpha: Bool = false, _ quality: ImageCompressor.Quality = .standard) -> ImageCompressor.Plan {
        ImageCompressor.plan(type: type, width: w, height: h, bytes: bytes, frames: frames,
                             hasAlpha: alpha, quality: quality)
    }

    func testStandardShrinksBigPhotosTo2048() {
        XCTAssertEqual(plan(.heic, 8064, 6048), .jpeg(maxPixels: 2048))
        XCTAssertEqual(plan(.jpeg, 4032, 3024), .jpeg(maxPixels: 2048))
        XCTAssertEqual(plan(.webP, 3000, 5000), .jpeg(maxPixels: 2048))
    }

    func testStandardNeverUpscales() {
        XCTAssertEqual(plan(.heic, 1600, 1200, bytes: 400_000), .jpeg(maxPixels: 1600))
        XCTAssertEqual(plan(.jpeg, 1600, 1200, bytes: 3_000_000), .jpeg(maxPixels: 1600))
    }

    func testStandardKeepsSmallJPEG() {
        XCTAssertEqual(plan(.jpeg, 2048, 1536, bytes: 1_500_000), .keep)
        XCTAssertEqual(plan(.jpeg, 2049, 1536, bytes: 900_000), .jpeg(maxPixels: 2048))
    }

    func testPNGStaysPNG() {
        XCTAssertEqual(plan(.png, 2796, 1290), .png(maxPixels: 2048))
        XCTAssertEqual(plan(.png, 1290, 1290), .keep)
        XCTAssertEqual(plan(.webP, 3000, 3000, alpha: true), .png(maxPixels: 2048))
    }

    func testAnimationIsLeftAlone() {
        XCTAssertEqual(plan(.gif, 4000, 4000), .keep)
        XCTAssertEqual(plan(.webP, 4000, 4000, frames: 12), .keep)
        XCTAssertEqual(plan(.heic, 4000, 4000, frames: 3), .keep)
    }

    func testOriginalOnlyConvertsHEIC() {
        XCTAssertEqual(plan(.heic, 8064, 6048, .original), .jpegFullSize)
        XCTAssertEqual(plan(.heif, 8064, 6048, .original), .jpegFullSize)
        XCTAssertEqual(plan(.jpeg, 8064, 6048, .original), .keep)
        XCTAssertEqual(plan(.png, 8064, 6048, .original), .keep)
    }

    func testUnreadableSizeKeeps() {
        XCTAssertEqual(plan(.jpeg, 0, 0), .keep)
    }

    // MARK: - Real encodes

    /// A noisy image with camera EXIF,
    /// a GPS block and an orientation tag.
    private func photo(_ type: UTType, width: Int, height: Int, orientation: Int = 1,
                       alpha: Bool = false) throws -> Data {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        let ctx = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: 0, space: space, bitmapInfo: info))
        // Per-pixel noise, like sensor grain: JPEG can't cheat on it.
        let buffer = try XCTUnwrap(ctx.data)
        arc4random_buf(buffer, ctx.bytesPerRow * height)
        if alpha {
            ctx.clear(CGRect(x: 0, y: 0, width: width / 2, height: height))
        }
        let image = try XCTUnwrap(ctx.makeImage())
        let data = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        let props: [CFString: Any] = [
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "Test Camera"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:11:26 10:00:00"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 39.33, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 82.98, kCGImagePropertyGPSLongitudeRef: "W"],
            kCGImageDestinationLossyCompressionQuality: 1.0
        ]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return data as Data
    }

    private func properties(_ data: Data) throws -> [CFString: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    func testStandardJPEGIsSmallerUprightAndHasNoMetadata() throws {
        let input = try photo(.jpeg, width: 4032, height: 3024, orientation: 6)
        let out = ImageCompressor.prepare(input, type: .jpeg, quality: .standard)
        XCTAssertEqual(out.type, .jpeg)
        XCTAssertLessThan(out.data.count, input.count)
        let p = try properties(out.data)
        // Orientation 6 (rotate 90°) is baked in: the landscape photo is now portrait.
        XCTAssertEqual(p[kCGImagePropertyPixelWidth] as? Int, 1536)
        XCTAssertEqual(p[kCGImagePropertyPixelHeight] as? Int, 2048)
        XCTAssertNil(p[kCGImagePropertyGPSDictionary])
        XCTAssertNil((p[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFModel])
        XCTAssertNil((p[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifDateTimeOriginal])
        XCTAssertNotEqual(p[kCGImagePropertyOrientation] as? Int, 6)
    }

    func testStandardHEICBecomesJPEG() throws {
        let input = try photo(.heic, width: 4032, height: 3024)
        let out = ImageCompressor.prepare(input, type: .heic, quality: .standard)
        XCTAssertEqual(out.type, .jpeg)
        XCTAssertEqual(try properties(out.data)[kCGImagePropertyPixelWidth] as? Int, 2048)
    }

    func testSmallJPEGGoesUpByteForByte() throws {
        let input = try photo(.jpeg, width: 640, height: 480)
        XCTAssertLessThan(input.count, ImageCompressor.keepAsIsBytes)
        XCTAssertEqual(ImageCompressor.prepare(input, type: .jpeg, quality: .standard).data, input)
    }

    func testTransparentPNGStaysPNG() throws {
        let input = try photo(.png, width: 3000, height: 2000, alpha: true)
        let out = ImageCompressor.prepare(input, type: .png, quality: .standard)
        XCTAssertEqual(out.type, .png)
        let p = try properties(out.data)
        XCTAssertEqual(p[kCGImagePropertyPixelWidth] as? Int, 2048)
        XCTAssertEqual(p[kCGImagePropertyHasAlpha] as? Bool, true)
    }

    func testOriginalKeepsJPEGAndFullSizeHEIC() throws {
        let jpeg = try photo(.jpeg, width: 4032, height: 3024)
        XCTAssertEqual(ImageCompressor.prepare(jpeg, type: .jpeg, quality: .original).data, jpeg)

        let heic = try photo(.heic, width: 4032, height: 3024, orientation: 6)
        let out = ImageCompressor.prepare(heic, type: .heic, quality: .original)
        XCTAssertEqual(out.type, .jpeg)
        let p = try properties(out.data)
        XCTAssertEqual(p[kCGImagePropertyPixelWidth] as? Int, 4032)
        // Metadata carries over (MediaPrivacy takes the GPS out afterwards).
        XCTAssertEqual(p[kCGImagePropertyOrientation] as? Int, 6)
        XCTAssertEqual((p[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFModel] as? String,
                       "Test Camera")
    }

    func testUnreadableDataIsReturnedAsIs() {
        let junk = Data("not a picture".utf8)
        XCTAssertEqual(ImageCompressor.prepare(junk, type: .jpeg, quality: .standard).data, junk)
    }

    func testCoverJPEGSizeCap() throws {
        let input = try photo(.png, width: 5000, height: 2500)
        let cover = try XCTUnwrap(ImageCompressor.jpeg(from: input, maxPixels: 2400))
        XCTAssertEqual(try properties(cover)[kCGImagePropertyPixelWidth] as? Int, 2400)
        XCTAssertNil(try properties(cover)[kCGImagePropertyGPSDictionary])
    }

    /// Before/after bytes for a real photo: `NV_COMPRESS_SAMPLE=/path/to.heic swift test --filter Sample`.
    func testSampleFileReport() throws {
        guard let path = ProcessInfo.processInfo.environment["NV_COMPRESS_SAMPLE"] else {
            throw XCTSkip("set NV_COMPRESS_SAMPLE to measure a real photo")
        }
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        let type = UTType(filenameExtension: url.pathExtension) ?? .jpeg
        let before = try properties(data)
        for quality in [ImageCompressor.Quality.standard, .original] {
            let start = Date()
            let out = ImageCompressor.prepare(data, type: type, quality: quality)
            let p = try properties(out.data)
            print("NV_COMPRESS \(quality): \(data.count) B \(before[kCGImagePropertyPixelWidth] ?? 0)x\(before[kCGImagePropertyPixelHeight] ?? 0) "
                  + "-> \(out.data.count) B \(p[kCGImagePropertyPixelWidth] ?? 0)x\(p[kCGImagePropertyPixelHeight] ?? 0) "
                  + "\(out.type.identifier) in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        }
    }
}
