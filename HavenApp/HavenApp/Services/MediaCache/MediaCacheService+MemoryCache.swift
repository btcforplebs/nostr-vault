import Foundation
import SwiftUI
import CryptoKit
import AVFoundation
import CoreMedia
import Combine

extension MediaCacheService {
    // MARK: - In-Memory Image Cache

    func cachedImage(for url: URL) -> PlatformImage? {
        return imageCache.object(forKey: url as NSURL)
    }

    func cacheImage(_ image: PlatformImage, for url: URL) {
        imageCache.setObject(image, forKey: url as NSURL, cost: Self.decodedCost(of: image))
    }

    /// Decoded-bitmap cost in bytes, from real pixel dimensions. NSImage.size
    /// is in points and honors DPI metadata — a 300-dpi photo under-reports by
    /// ~17×, which let the 40 MB totalCostLimit admit hundreds of MB of
    /// decoded bitmaps before evicting anything.
    static func decodedCost(of image: PlatformImage) -> Int {
        #if os(macOS)
        var pixels = 0
        for rep in image.representations {
            pixels = max(pixels, rep.pixelsWide * rep.pixelsHigh)
        }
        if pixels == 0 {
            pixels = Int(image.size.width * image.size.height)
        }
        return pixels * 4
        #else
        return Int(image.size.width * image.scale * image.size.height * image.scale) * 4
        #endif
    }

    func handleMemoryPressure() {
        imageCache.removeAllObjects()
        thumbnailMemoryCache.removeAllObjects()
        VideoPlayerCache.shared.evictAll()
        #if DEBUG
        print("MediaCacheService: Purged in-memory caches due to memory pressure")
        #endif
    }

    /// Shrink the suspended-app footprint: drop the large full-res image cache and
    /// video buffers, but keep the small thumbnail cache so the feed scrolls
    /// instantly when the user returns. Everything dropped reloads from disk.
    func handleBackgrounding() {
        imageCache.removeAllObjects()
        VideoPlayerCache.shared.evictAll()
        #if DEBUG
        print("MediaCacheService: Dropped full-res image/video caches on backgrounding")
        #endif
    }
}
