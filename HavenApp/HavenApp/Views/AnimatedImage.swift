import SwiftUI
import ImageIO
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct ImageDownsampler {
    /// Downsamples image data to a specific maximum dimension using ImageIO.
    /// This avoids decoding the full image into memory.
    static func downsample(data: Data, maxDimension: CGFloat) async -> PlatformImage? {
        // Capture scale on the main actor before entering the detached task.
        // UIScreen.main is @MainActor in Swift 6 and cannot be accessed from a detached task.
        #if os(macOS)
        let scale: CGFloat = await MainActor.run { NSScreen.main?.backingScaleFactor ?? 2.0 }
        #else
        let scale: CGFloat = await MainActor.run { UIScreen.main.scale }
        #endif

        return await Task.detached(priority: .utility) {
            // Create an image source from the data
            let options = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithData(data as CFData, options) else {
                return nil
            }
            
            // Calculate the desired pixel size
            let maxPixelSize = Int(maxDimension * scale)
            
            let downsampleOptions = [
                kCGImageSourceCreateThumbnailFromImageAlways: kCFBooleanTrue,
                kCGImageSourceCreateThumbnailWithTransform: kCFBooleanTrue, 
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize as NSNumber
            ] as CFDictionary
            
            if CGImageSourceGetCount(source) < 1 {
                return nil
            }
            
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions) else {
                return nil
            }
            
            #if os(macOS)
            return NSImage(cgImage: cgImage, size: .zero)
            #else
            return UIImage(cgImage: cgImage)
            #endif
        }.value
    }

    /// Downsamples to the main screen's larger dimension — the most a
    /// full-screen view can display. Decoding beyond that only burns memory
    /// (a 48 MP photo is ~190 MB decoded). Returns nil if ImageIO can't read
    /// the data; callers fall back to a plain decode.
    static func downsampleToScreen(data: Data) async -> PlatformImage? {
        #if os(macOS)
        let dimension: CGFloat = await MainActor.run {
            let frame = NSScreen.main?.frame
            return max(frame?.width ?? 1728, frame?.height ?? 1117)
        }
        #else
        let dimension: CGFloat = await MainActor.run {
            let bounds = UIScreen.main.bounds
            return max(bounds.width, bounds.height)
        }
        #endif
        return await downsample(data: data, maxDimension: dimension)
    }
}

struct AnimatedImageHelper {
    /// Sniffs the GIF87a / GIF89a magic bytes for extensionless URLs (blossom hashes).
    static func isGIFData(_ data: Data) -> Bool {
        guard data.count >= 6 else { return false }
        let magic = data.prefix(6)
        return magic == Data("GIF87a".utf8) || magic == Data("GIF89a".utf8)
    }

    /// RIFF....WEBP container. Single-frame WebP decodes to one frame and
    /// shows still, so this is safe to route through the animated path.
    static func isWebPData(_ data: Data) -> Bool {
        data.count >= 12 && data.prefix(4) == Data("RIFF".utf8) && data[data.startIndex + 8 ..< data.startIndex + 12] == Data("WEBP".utf8)
    }
}

#if os(macOS)
struct AnimatedImage: NSViewRepresentable {
    let url: URL
    var contentMode: ContentMode = .fit
    var shouldAnimate: Bool = true
    var targetSize: CGSize? = nil
    /// Static image to show if `url` fetches successfully but decodes to
    /// nothing (e.g. a CDN variant that 200s with an empty body).
    var fallbackURL: URL? = nil
    var onLoad: ((CGSize) -> Void)? = nil

    func makeNSView(context: Context) -> AspectFillImageView {
        let view = AspectFillImageView()
        view.contentMode = contentMode
        view.shouldAnimate = shouldAnimate
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        loadAsync(url: url, into: view)
        return view
    }

    func updateNSView(_ nsView: AspectFillImageView, context: Context) {
        nsView.contentMode = contentMode
        nsView.shouldAnimate = shouldAnimate
    }

    private func loadAsync(url: URL, into view: AspectFillImageView) {
        // Check in-memory cache first for instant rendering. Skipped when animation
        // is requested: the cache may hold a static first-frame decode left behind
        // by a non-animating caller (e.g. a grid thumbnail) for the same URL.
        if self.shouldAnimate == false, let cached = MediaCacheService.shared.cachedImage(for: url) {
            view.image = cached
            onLoad?(cached.size)
            return
        }

        Task.detached(priority: .utility) {
            let data: Data?
            if let cached = MediaCacheService.shared.loadFromCache(url: url) {
                data = cached
            } else {
                data = await MediaCacheService.shared.fetchData(url: url)
            }

            guard let data else { return }

            let image: PlatformImage?
            let isGIF = url.pathExtension.lowercased() == "gif" || AnimatedImageHelper.isGIFData(data)

            if isGIF {
                // On macOS, NSImage natively handles animated GIFs when loaded from Data
                image = NSImage(data: data)
            } else if let targetSize = self.targetSize {
                image = await ImageDownsampler.downsample(data: data, maxDimension: max(targetSize.width, targetSize.height))
            } else {
                // No explicit target: bound the decode to screen pixels instead
                // of materializing the full-resolution original.
                image = await ImageDownsampler.downsampleToScreen(data: data) ?? NSImage(data: data)
            }

            guard let image else {
                await self.loadFallback(into: view)
                return
            }

            // Cache static images and non-animated GIF thumbnails in memory
            if !isGIF || !self.shouldAnimate {
                await MainActor.run {
                    MediaCacheService.shared.cacheImage(image, for: url)
                }
            }

            await MainActor.run {
                view.image = image
                self.onLoad?(image.size)
            }
        }
    }

    private func loadFallback(into view: AspectFillImageView) async {
        guard let fallbackURL else { return }
        guard let data = await MediaCacheService.shared.fetchData(url: fallbackURL) else { return }
        guard let image = NSImage(data: data) else { return }
        await MainActor.run {
            view.image = image
            self.onLoad?(image.size)
        }
    }
}

class AspectFillImageView: NSView {
    private let imageView = NSImageView()
    
    var image: NSImage? {
        get { imageView.image }
        set {
            imageView.image = newValue
            needsLayout = true
        }
    }
    
    var contentMode: ContentMode = .fit {
        didSet {
            needsLayout = true
        }
    }
    
    var shouldAnimate: Bool = true {
        didSet {
            imageView.animates = shouldAnimate
        }
    }
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }
    
    private func setup() {
        wantsLayer = true
        layer?.masksToBounds = true
        imageView.animates = shouldAnimate
        imageView.imageScaling = .scaleAxesIndependently
        addSubview(imageView)
    }
    
    override func layout() {
        super.layout()
        
        guard let image = imageView.image else { return }
        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0 else { return }
        
        let viewSize = bounds.size
        let widthRatio = viewSize.width / imageSize.width
        let heightRatio = viewSize.height / imageSize.height
        
        var scale: CGFloat
        
        switch contentMode {
        case .fill:
            scale = max(widthRatio, heightRatio)
        case .fit:
            scale = min(widthRatio, heightRatio)
        }
        
        let scaledWidth = imageSize.width * scale
        let scaledHeight = imageSize.height * scale
        
        let x = (viewSize.width - scaledWidth) / 2
        let y = (viewSize.height - scaledHeight) / 2
        
        imageView.frame = NSRect(x: x, y: y, width: scaledWidth, height: scaledHeight)
    }
}
#else
struct AnimatedImage: UIViewRepresentable {
    let url: URL
    var contentMode: ContentMode = .fit
    var shouldAnimate: Bool = true
    var targetSize: CGSize? = nil
    /// Static image to show if `url` fetches successfully but decodes to
    /// nothing (e.g. a CDN variant that 200s with an empty body).
    var fallbackURL: URL? = nil
    var onLoad: ((CGSize) -> Void)? = nil

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = contentMode == .fill ? .scaleAspectFill : .scaleAspectFit
        view.clipsToBounds = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        loadAsync(url: url, into: view)
        return view
    }

    func updateUIView(_ uiView: UIImageView, context: Context) {
        uiView.contentMode = contentMode == .fill ? .scaleAspectFill : .scaleAspectFit
    }

    private func loadAsync(url: URL, into view: UIImageView) {
        // Check in-memory cache first for instant rendering. Skipped when animation
        // is requested: the cache may hold a static first-frame decode left behind
        // by a non-animating caller (e.g. a grid thumbnail) for the same URL.
        if self.shouldAnimate == false, let cached = MediaCacheService.shared.cachedImage(for: url) {
            view.image = cached
            onLoad?(cached.size)
            return
        }

        Task.detached(priority: .utility) {
            let data: Data?
            if let cached = MediaCacheService.shared.loadFromCache(url: url) {
                data = cached
            } else {
                data = await MediaCacheService.shared.fetchData(url: url)
            }

            guard let data else { return }

            let image: UIImage?
            // Animated WebP (nostr.build GIF previews) plays through the same
            // frame decoder; UIImage(data:) would show only its first frame.
            let isGIF = url.isGIF || AnimatedImageHelper.isGIFData(data) || AnimatedImageHelper.isWebPData(data)

            if isGIF {
                if self.shouldAnimate {
                    // A target size bounds every frame's decode, so a small
                    // animated thumbnail doesn't hold full-size frames.
                    var maxPixelSize: Int?
                    if let targetSize = self.targetSize {
                        let scale = await MainActor.run { UIScreen.main.scale }
                        maxPixelSize = Int(max(targetSize.width, targetSize.height) * scale)
                    }
                    image = Self.makeAnimatedGIF(data: data, maxPixelSize: maxPixelSize)
                } else {
                    image = UIImage(data: data)
                }
            } else if let targetSize = self.targetSize {
                image = await ImageDownsampler.downsample(data: data, maxDimension: max(targetSize.width, targetSize.height))
            } else {
                // No explicit target: bound the decode to screen pixels instead
                // of materializing the full-resolution original.
                image = await ImageDownsampler.downsampleToScreen(data: data) ?? UIImage(data: data)
            }

            guard let image else {
                await self.loadFallback(into: view)
                return
            }

            // Cache static images and non-animated GIF thumbnails in memory
            if !isGIF || !self.shouldAnimate {
                await MainActor.run {
                    MediaCacheService.shared.cacheImage(image, for: url)
                }
            }

            await MainActor.run {
                view.image = image
                self.onLoad?(image.size)
            }
        }
    }

    private func loadFallback(into view: UIImageView) async {
        guard let fallbackURL else { return }
        guard let data = await MediaCacheService.shared.fetchData(url: fallbackURL) else { return }
        guard let image = UIImage(data: data) else { return }
        await MainActor.run {
            view.image = image
            self.onLoad?(image.size)
        }
    }

    /// Decodes all GIF frames via CGImageSource and returns an animating UIImage.
    /// UIImage(data:) only decodes the first frame, so looping requires this.
    nonisolated private static func makeAnimatedGIF(data: Data, maxPixelSize: Int? = nil) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 1 else { return UIImage(data: data) }
        let thumbnailOptions = maxPixelSize.map {
            [
                kCGImageSourceCreateThumbnailFromImageAlways: kCFBooleanTrue,
                kCGImageSourceCreateThumbnailWithTransform: kCFBooleanTrue,
                kCGImageSourceThumbnailMaxPixelSize: $0 as NSNumber
            ] as CFDictionary
        }

        var frames: [UIImage] = []
        var totalDuration: Double = 0

        for i in 0..<count {
            let frame = thumbnailOptions.map { CGImageSourceCreateThumbnailAtIndex(source, i, $0) }
                ?? CGImageSourceCreateImageAtIndex(source, i, nil)
            guard let cgImage = frame else { continue }
            frames.append(UIImage(cgImage: cgImage))
            let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [String: Any]
            let gifDict = props?[kCGImagePropertyGIFDictionary as String] as? [String: Any]
            let webpDict = props?[kCGImagePropertyWebPDictionary as String] as? [String: Any]
            let delay = gifDict?[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double
                     ?? gifDict?[kCGImagePropertyGIFDelayTime as String] as? Double
                     ?? webpDict?[kCGImagePropertyWebPUnclampedDelayTime as String] as? Double
                     ?? webpDict?[kCGImagePropertyWebPDelayTime as String] as? Double
                     ?? 0.1
            totalDuration += max(delay, 0.011)
        }

        return UIImage.animatedImage(with: frames, duration: totalDuration)
    }

}
#endif

// URL media type helpers are now in SupportedMediaFormats.swift

