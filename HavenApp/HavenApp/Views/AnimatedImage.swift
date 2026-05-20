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
}

#if os(macOS)
struct AnimatedImage: NSViewRepresentable {
    let url: URL
    var contentMode: ContentMode = .fit
    var shouldAnimate: Bool = true
    var targetSize: CGSize? = nil
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
        Task.detached(priority: .utility) {
            let data: Data?
            if let cached = MediaCacheService.shared.loadFromCache(url: url) {
                data = cached
            } else {
                data = await MediaCacheService.shared.fetchData(url: url)
            }

            guard let data else { return }

            let image: PlatformImage?
            if let targetSize = self.targetSize {
                image = await ImageDownsampler.downsample(data: data, maxDimension: max(targetSize.width, targetSize.height))
            } else {
                image = NSImage(data: data)
            }

            guard let image else { return }
            await MainActor.run {
                view.image = image
                self.onLoad?(image.size)
            }
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
        Task.detached(priority: .utility) {
            let data: Data?
            if let cached = MediaCacheService.shared.loadFromCache(url: url) {
                data = cached
            } else {
                data = await MediaCacheService.shared.fetchData(url: url)
            }

            guard let data else { return }

            let image: UIImage?
            if let targetSize = self.targetSize {
                image = await ImageDownsampler.downsample(data: data, maxDimension: max(targetSize.width, targetSize.height))
            } else if url.isGIF {
                image = Self.makeAnimatedGIF(data: data)
            } else {
                image = UIImage(data: data)
            }

            guard let image else { return }
            await MainActor.run {
                view.image = image
                self.onLoad?(image.size)
            }
        }
    }

    /// Decodes all GIF frames via CGImageSource and returns an animating UIImage.
    /// UIImage(data:) only decodes the first frame, so looping requires this.
    private static func makeAnimatedGIF(data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 1 else { return UIImage(data: data) }

        var frames: [UIImage] = []
        var totalDuration: Double = 0

        for i in 0..<count {
            guard let cgImage = CGImageSourceCreateImageAtIndex(source, i, nil) else { continue }
            frames.append(UIImage(cgImage: cgImage))
            let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [String: Any]
            let gifDict = props?[kCGImagePropertyGIFDictionary as String] as? [String: Any]
            let delay = gifDict?[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double
                     ?? gifDict?[kCGImagePropertyGIFDelayTime as String] as? Double
                     ?? 0.1
            totalDuration += max(delay, 0.011)
        }

        return UIImage.animatedImage(with: frames, duration: totalDuration)
    }
}
#endif

// Helper to determine if a URL represents a GIF
extension URL {
    var isGIF: Bool {
        return self.pathExtension.lowercased() == "gif"
    }
    
    var isVideo: Bool {
        let ext = self.pathExtension.lowercased()
        return ext == "mov" || ext == "mp4" || ext == "webm"
    }
    
    var isWebP: Bool {
        return self.pathExtension.lowercased() == "webp"
    }
    
    var isAudio: Bool {
        let ext = self.pathExtension.lowercased()
        return ["mp3", "wav", "m4a", "aac", "flac", "ogg"].contains(ext)
    }
    
    var isImage: Bool {
        let ext = self.pathExtension.lowercased()
        if ["jpg", "jpeg", "png", "gif", "webp", "heic", "tiff"].contains(ext) { return true }
        if ext.isEmpty {
            let last = self.lastPathComponent
            let pattern = "^[a-f0-9]{64}$"
            return last.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
        return false
    }
}

