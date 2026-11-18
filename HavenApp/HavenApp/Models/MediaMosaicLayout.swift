import Foundation
import CoreGraphics
import ImageIO

/// Masonry maths for the Vault's Media tab.
///
/// Each photo or video keeps its own shape: fixed-width columns, each tile
/// placed in whichever column is shortest so far, and each tile's height
/// worked out from the media's known size before any pixels load. A tile
/// whose size is not known is square. Because every height is known up
/// front, the grid never re-measures a tile when its image arrives.
///
/// Kept free of SwiftUI so it can be tested directly; the view supplies the
/// measured width and the column count.
enum MediaMosaicLayout {
    /// Narrowest shape a tile may take, as width / height: twice as tall as
    /// wide. A tall screenshot would otherwise be a column-long sliver.
    static let minAspect: Double = 0.5
    /// Widest shape a tile may take: a panorama would otherwise be a line.
    static let maxAspect: Double = 2.0

    /// `aspect` limited to what a tile may show; 1 (square) when unknown.
    static func clampedAspect(_ aspect: Double?) -> Double {
        guard let aspect, aspect.isFinite, aspect > 0 else { return 1 }
        return min(max(aspect, minAspect), maxAspect)
    }

    /// Width of one column once the gaps are taken out.
    static func columnWidth(forWidth width: Double, columns: Int, spacing: Double) -> Double {
        guard columns > 0 else { return max(0, width) }
        return max(0, (width - spacing * Double(columns - 1)) / Double(columns))
    }

    /// Height of a tile `columnWidth` wide, in whole points.
    static func tileHeight(columnWidth: Double, aspect: Double?) -> Double {
        (columnWidth / clampedAspect(aspect)).rounded()
    }

    /// Deals `items` into `columns` columns, each going to the column that is
    /// shortest so far. Ties go to the leftmost column, so the first items
    /// read across the top row in order. Order within a column is kept, and
    /// appending items never moves the ones already placed (a new page of
    /// media does not reshuffle what is on screen).
    static func distribute<T>(_ items: [T], columns: Int, spacing: Double,
                              aspect: (T) -> Double?) -> [[T]] {
        let count = max(1, columns)
        var buckets: [[T]] = Array(repeating: [], count: count)
        var filled = [Double](repeating: 0, count: count)
        for item in items {
            var shortest = 0
            for index in 1..<count where filled[index] < filled[shortest] - 0.0001 {
                shortest = index
            }
            buckets[shortest].append(item)
            // Unit-width heights: every column is the same width, so the
            // width cancels out of which column is shortest.
            filled[shortest] += 1 / clampedAspect(aspect(item)) + spacing / 100
        }
        return buckets
    }

    // MARK: - Known sizes

    /// width / height from the note's NIP-92 `imeta` tag for this media.
    /// The tag is matched by its `url`, or by the blob hash (`x`, or a `url`
    /// holding it), since the tab may show a mirror's address for the file.
    static func aspect(tags: [[String]]?, url: URL, hash: String?) -> Double? {
        guard let tags else { return nil }
        let urlString = url.absoluteString
        for tag in tags where tag.first == "imeta" {
            var tagURL: String?
            var x: String?
            var dim: String?
            for field in tag.dropFirst() {
                guard let space = field.firstIndex(of: " ") else { continue }
                let value = field[field.index(after: space)...].trimmingCharacters(in: .whitespaces)
                switch field[..<space] {
                case "url": tagURL = value
                case "x": x = value.lowercased()
                case "dim": dim = value
                default: continue
                }
            }
            let sameURL = tagURL == urlString
            let sameHash = hash.map { h in x == h || (tagURL?.lowercased().contains(h) ?? false) } ?? false
            guard sameURL || sameHash, let dim, let ratio = aspect(fromDim: dim) else { continue }
            return ratio
        }
        return nil
    }

    /// width / height from an imeta `dim` value such as `1920x1080`.
    static func aspect(fromDim dim: String) -> Double? {
        let parts = dim.lowercased().split(separator: "x")
        guard parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]),
              w > 0, h > 0 else { return nil }
        return w / h
    }

    /// width / height as the photo is shown: EXIF orientations 5 to 8 turn
    /// the picture a quarter, so its stored width is its shown height.
    static func shownAspect(pixelWidth: Double, pixelHeight: Double, orientation: Int) -> Double? {
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }
        return (5...8).contains(orientation) ? pixelHeight / pixelWidth : pixelWidth / pixelHeight
    }

    /// width / height of an image file, read from its header only (no decode).
    static func imageFileAspect(at fileURL: URL) -> Double? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, options),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue else { return nil }
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return shownAspect(pixelWidth: w, pixelHeight: h, orientation: orientation)
    }
}

/// Shapes the Media tab has learned, by blob hash (or address when there is
/// no hash). The local scan fills it from each photo's file header off the
/// main thread, so the grid can size a tile before the photo loads.
final class MediaMosaicSizes: @unchecked Sendable {
    static let shared = MediaMosaicSizes()

    private let lock = NSLock()
    private var aspects: [String: Double] = [:]

    func aspect(for key: String) -> Double? {
        lock.lock(); defer { lock.unlock() }
        return aspects[key]
    }

    func record(_ aspect: Double, for key: String) {
        guard aspect.isFinite, aspect > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        aspects[key] = aspect
    }

    /// Reads the file's header once and keeps its shape under `key`.
    func recordImageFile(_ fileURL: URL, key: String) {
        if aspect(for: key) != nil { return }
        if let aspect = MediaMosaicLayout.imageFileAspect(at: fileURL) { record(aspect, for: key) }
    }
}
