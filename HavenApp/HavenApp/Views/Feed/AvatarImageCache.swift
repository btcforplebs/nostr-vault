import SwiftUI
import ImageIO
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

final class AvatarImageCache {
    static let shared = AvatarImageCache()

    private let cache = NSCache<NSURL, PlatformImage>()
    private var inFlight: [URL: [(PlatformImage?) -> Void]] = [:]
    private let lock = NSLock()

    // Downsample target — large enough for a profile header on @3x retina,
    // small enough that 300 entries fit in ~24 MB.
    private static let targetPixelSize: CGFloat = 256
    private static let estimatedCostPerEntry = 256 * 256 * 4 // bytes

    init() {
        cache.countLimit = 300
        cache.totalCostLimit = 24 * 1024 * 1024
    }

    func image(for url: URL) -> PlatformImage? {
        cache.object(forKey: url as NSURL)
    }

    private func store(_ image: PlatformImage, for url: URL) {
        cache.setObject(image, forKey: url as NSURL, cost: Self.estimatedCostPerEntry)
    }

    /// Loads an avatar, hitting (in order): memory cache → on-disk cache → network.
    /// Coalesces concurrent requests for the same URL and skips known-404s.
    /// `completion` is always called on the main thread.
    func load(url: URL, completion: @escaping (PlatformImage?) -> Void) {
        if let cached = image(for: url) {
            completion(cached)
            return
        }
        if MediaCacheService.shared.isKnown404(url: url) {
            completion(nil)
            return
        }

        lock.lock()
        if inFlight[url] != nil {
            inFlight[url]?.append(completion)
            lock.unlock()
            return
        }
        inFlight[url] = [completion]
        lock.unlock()

        MediaCacheService.shared.downloadQueue.addOperation { [weak self] in
            guard let self = self else { return }
            let cache = MediaCacheService.shared
            let size = Int(Self.targetPixelSize)

            // The small copy on disk
            if let data = cache.avatarThumbnailData(for: url, maxPixel: size),
               let img = Self.downsample(data: data) {
                self.finish(url: url, image: Self.platformImage(img))
                return
            }

            // An original already on disk (saved by an older build, or by a
            // view that keeps full-size pictures): shrink it once, keep that.
            if let data = cache.loadFromCache(url: url),
               let img = Self.downsample(data: data) {
                Self.keepSmallCopy(img, for: url)
                self.finish(url: url, image: Self.platformImage(img))
                return
            }

            // A `.fips` picture is reachable only over the mesh.
            if MediaCacheService.isMeshOnly(url) {
                self.finish(url: url, image: nil)
                return
            }

            // Network. Only the small copy is kept; the original is dropped.
            URLSession.shared.dataTask(with: AvatarThumbnail.url(for: url)) { data, response, _ in
                guard let data = data,
                      let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      let img = Self.downsample(data: data) else {
                    self.finish(url: url, image: nil)
                    return
                }
                Self.keepSmallCopy(img, for: url)
                self.finish(url: url, image: Self.platformImage(img))
            }.resume()
        }
    }

    /// Async form of `load`, for callers that only want the picture on disk.
    func load(url: URL) async -> PlatformImage? {
        await withCheckedContinuation { continuation in
            load(url: url) { continuation.resume(returning: $0) }
        }
    }

    func hasSmallCopy(of url: URL) -> Bool {
        MediaCacheService.shared.hasAvatarThumbnail(for: url, maxPixel: Int(Self.targetPixelSize))
    }

    /// The small copy's bytes, for readers that only need a rough look at
    /// the picture (the profile tint).
    func smallCopyData(of url: URL) -> Data? {
        MediaCacheService.shared.avatarThumbnailData(for: url, maxPixel: Int(Self.targetPixelSize))
    }

    /// JPEG, or PNG when the picture has transparency (JPEG would fill it black).
    private static func keepSmallCopy(_ image: CGImage, for url: URL) {
        let alpha = image.alphaInfo
        let opaque = alpha == .none || alpha == .noneSkipFirst || alpha == .noneSkipLast
        let type = (opaque ? UTType.jpeg : UTType.png).identifier as CFString
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, opaque ? [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary : nil)
        guard CGImageDestinationFinalize(dest) else { return }
        MediaCacheService.shared.saveAvatarThumbnail(data as Data, for: url, maxPixel: Int(targetPixelSize))
    }

    private static func platformImage(_ cgImage: CGImage) -> PlatformImage {
        #if canImport(AppKit)
        return NSImage(cgImage: cgImage, size: .zero)
        #else
        return UIImage(cgImage: cgImage)
        #endif
    }

    private func finish(url: URL, image: PlatformImage?) {
        if let image = image {
            store(image, for: url)
        }
        lock.lock()
        let callbacks = inFlight.removeValue(forKey: url) ?? []
        lock.unlock()
        DispatchQueue.main.async {
            callbacks.forEach { $0(image) }
        }
    }

    private static func downsample(data: Data) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: targetPixelSize
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
