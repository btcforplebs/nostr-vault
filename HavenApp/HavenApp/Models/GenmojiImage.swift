import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A Genmoji's picture as a PNG to publish. `NSAdaptiveImageGlyph.imageContent`
/// is one HEIC holding the same square image at several sizes; other apps
/// (Android, Chrome) don't reliably draw HEIC, so the largest frame goes out
/// as PNG with its transparency kept (RESEARCH/NV_GENMOJI_STARTER_SET.md §1).
enum GenmojiImage {
    /// The largest frame of `data` (any format ImageIO reads) as PNG, or nil
    /// when it holds no image.
    static func largestFramePNG(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        var best: CGImage?
        for i in 0..<CGImageSourceGetCount(source) {
            guard let image = CGImageSourceCreateImageAtIndex(source, i, nil) else { continue }
            if image.width * image.height > (best.map { $0.width * $0.height } ?? 0) { best = image }
        }
        guard let best else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, best, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
