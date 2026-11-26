import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Shrinks a photo before it is uploaded (RESEARCH/NV_UPLOAD_COMPRESSION_2026_11_26.md §4.1,
/// with Logen's 2048 px call).
///
/// - **Standard** (notes, Share Portal posts, live chat): long edge at most
///   2048 px, never upscaled, orientation applied, JPEG at quality 0.82. The
///   re-encode writes no metadata at all (no GPS, camera, serial or date). A
///   JPEG that is already small enough goes up byte for byte. PNG stays PNG
///   (screenshots and transparency), only resized. GIFs and animated images
///   are left alone.
/// - **Original** (the Media tab, your own backup): full size. Only HEIC/HEIF
///   is re-encoded, to JPEG, because most readers can't draw it; its other
///   metadata is kept.
///
/// Either way the caller still runs `MediaPrivacy`, so the location never
/// goes up. Uses ImageIO thumbnails, so a 48 MP photo is never decoded at
/// full size for a Standard upload.
enum ImageCompressor {
    enum Quality: Sendable {
        case standard
        case original
    }

    /// What one photo should become.
    enum Plan: Equatable, Sendable {
        /// Upload the bytes as they are.
        case keep
        /// Re-encode as JPEG, long edge at most `maxPixels`.
        case jpeg(maxPixels: Int)
        /// Re-encode as JPEG at full size, keeping the source's metadata
        /// (Original HEIC).
        case jpegFullSize
        /// Re-encode as PNG, long edge at most `maxPixels`.
        case png(maxPixels: Int)
    }

    /// The result: the bytes to upload and their type.
    struct Output: Equatable, Sendable {
        let data: Data
        let type: UTType
        var mimeType: String { type.preferredMIMEType ?? "image/jpeg" }
    }

    static let standardMaxPixels = 2048
    static let standardJPEGQuality = 0.82
    static let originalJPEGQuality = 0.9
    /// A JPEG at or under this size (and already small enough in pixels)
    /// isn't worth re-encoding.
    static let keepAsIsBytes = 1_500_000

    // MARK: - Rules

    /// The rules of §4.1, kept free of ImageIO so they can be tested alone.
    static func plan(type: UTType, width: Int, height: Int, bytes: Int,
                     frames: Int, hasAlpha: Bool, quality: Quality) -> Plan {
        if frames > 1 || type.conforms(to: .gif) { return .keep }
        let isHEIC = type.conforms(to: .heic) || type.conforms(to: .heif)
        switch quality {
        case .original:
            return isHEIC ? .jpegFullSize : .keep
        case .standard:
            let longEdge = max(width, height)
            guard longEdge > 0 else { return .keep }
            let target = min(longEdge, standardMaxPixels)
            if type.conforms(to: .png) {
                return longEdge > standardMaxPixels ? .png(maxPixels: target) : .keep
            }
            if hasAlpha && !isHEIC {
                // A transparent WebP/TIFF: JPEG would paint the clear parts black.
                return .png(maxPixels: target)
            }
            if type.conforms(to: .jpeg), longEdge <= standardMaxPixels, bytes <= keepAsIsBytes {
                return .keep
            }
            return .jpeg(maxPixels: target)
        }
    }

    // MARK: - Compressing

    /// The photo to upload for `data`. Falls back to the bytes as they are
    /// when they can't be read or the plan is to keep them.
    static func prepare(_ data: Data, type: UTType, quality: Quality) -> Output {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let output = compress(source, type: type, bytes: data.count, quality: quality)
        else { return Output(data: data, type: type) }
        return output
    }

    /// The photo file at `url`, compressed; nil when it should go up as it is
    /// (or can't be read).
    static func compressed(fileAt url: URL, type: UTType, quality: Quality) -> Output? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max
        return compress(source, type: type, bytes: bytes, quality: quality)
    }

    /// Any image as an upright JPEG, long edge at most `maxPixels`, with no
    /// metadata. Covers, listings and DM photos use this with their own sizes.
    static func jpeg(from data: Data, maxPixels: Int, quality: Double = 0.8) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = thumbnail(source, maxPixels: maxPixels) else { return nil }
        return encode(image, as: .jpeg, quality: quality)
    }

    private static func compress(_ source: CGImageSource, type: UTType, bytes: Int, quality: Quality) -> Output? {
        let sourceType = CGImageSourceGetType(source).flatMap { UTType($0 as String) } ?? type
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        let hasAlpha = properties[kCGImagePropertyHasAlpha] as? Bool ?? false
        let plan = plan(type: sourceType, width: width, height: height, bytes: bytes,
                        frames: CGImageSourceGetCount(source), hasAlpha: hasAlpha, quality: quality)
        switch plan {
        case .keep:
            return nil
        case .jpeg(let maxPixels):
            guard let image = thumbnail(source, maxPixels: maxPixels),
                  let data = encode(image, as: .jpeg, quality: standardJPEGQuality) else { return nil }
            return Output(data: data, type: .jpeg)
        case .png(let maxPixels):
            guard let image = thumbnail(source, maxPixels: maxPixels),
                  let data = encode(image, as: .png, quality: nil) else { return nil }
            return Output(data: data, type: .png)
        case .jpegFullSize:
            // From the source, so the orientation tag and the rest of the
            // metadata carry over; MediaPrivacy then takes the location out.
            let data = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
            else { return nil }
            CGImageDestinationAddImageFromSource(dest, source, 0,
                                                 [kCGImageDestinationLossyCompressionQuality: originalJPEGQuality] as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { return nil }
            return Output(data: data as Data, type: .jpeg)
        }
    }

    /// The first frame, upright, long edge at most `maxPixels`.
    private static func thumbnail(_ source: CGImageSource, maxPixels: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// `image` encoded with no metadata.
    private static func encode(_ image: CGImage, as type: UTType, quality: Double?) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        let options: [CFString: Any] = quality.map { [kCGImageDestinationLossyCompressionQuality: $0] } ?? [:]
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
