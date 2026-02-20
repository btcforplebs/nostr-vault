import SwiftUI
import AppKit
import ImageIO

struct ImageDownsampler {
    /// Downsamples image data to a specific maximum dimension using ImageIO.
    /// This avoids decoding the full image into memory.
    static func downsample(data: Data, maxDimension: CGFloat) async -> NSImage? {
        return await Task.detached(priority: .utility) {
            // Create an image source from the data
            let options = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithData(data as CFData, options) else {
                return nil
            }
            
            // Calculate the desired pixel size
            // We use a scale factor (e.g. 2x for Retina) to ensure it looks sharp
            let scale = NSScreen.main?.backingScaleFactor ?? 2.0
            let maxPixelSize = Int(maxDimension * scale)
            
            // Downsample options - Key note: ImageIO expects CFNumber/CFBoolean, not pure Swift types sometimes.
            // We cast numeric/bool values to be safe.
            let downsampleOptions = [
                kCGImageSourceCreateThumbnailFromImageAlways: kCFBooleanTrue,
                kCGImageSourceCreateThumbnailWithTransform: kCFBooleanTrue, 
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize as NSNumber
            ] as CFDictionary
            
            // Generate the thumbnail
            if CGImageSourceGetCount(source) < 1 {
                return nil
            }
            
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions) else {
                return nil
            }
            
            // Convert back to NSImage
            return NSImage(cgImage: cgImage, size: NSZeroSize)
        }.value
    }
}

struct AnimatedImage: NSViewRepresentable {
    let url: URL
    var contentMode: ContentMode = .fit
    var shouldAnimate: Bool = true
    var targetSize: CGSize? = nil
    
    func makeNSView(context: Context) -> AspectFillImageView {
        let view = AspectFillImageView()
        view.contentMode = contentMode
        view.shouldAnimate = shouldAnimate
        loadAsync(url: url, into: view)
        return view
    }
    
    func updateNSView(_ nsView: AspectFillImageView, context: Context) {
        nsView.contentMode = contentMode
        nsView.shouldAnimate = shouldAnimate
    }
    
    private func loadAsync(url: URL, into view: AspectFillImageView) {
        // Use utility priority to avoid priority inversions with ImageIO on the cooperative thread pool
        Task.detached(priority: .utility) {
            // Check cache first
            let data: Data?
            if let cached = MediaCacheService.shared.loadFromCache(url: url) {
                data = cached
            } else {
                data = await MediaCacheService.shared.fetchData(url: url)
            }

            guard let data else { return }

            // Decode/downsample off main thread
            let image: NSImage?
            if let targetSize = self.targetSize {
                image = await ImageDownsampler.downsample(data: data, maxDimension: max(targetSize.width, targetSize.height))
            } else {
                image = NSImage(data: data)
            }

            guard let image else { return }
            await MainActor.run {
                view.image = image
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
        // Configure Container
        wantsLayer = true
        layer?.masksToBounds = true
        
        // Configure Inner ImageView
        imageView.animates = shouldAnimate
        imageView.imageScaling = .scaleAxesIndependently // We manually size it, so this fills our calculated frame
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
            // Aspect Fill: Use the LARGER ratio so we fill the bounds completely
            scale = max(widthRatio, heightRatio)
        case .fit:
            // Aspect Fit: Use the SMALLER ratio so we fit entirely within bounds
            scale = min(widthRatio, heightRatio)
        }
        
        let scaledWidth = imageSize.width * scale
        let scaledHeight = imageSize.height * scale
        
        // Center the image
        let x = (viewSize.width - scaledWidth) / 2
        let y = (viewSize.height - scaledHeight) / 2
        
        imageView.frame = NSRect(x: x, y: y, width: scaledWidth, height: scaledHeight)
    }
}

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
        // For extensionless URLs (like Blossom hashes), assume it's an image
        // as they are far more common than extensionless videos.
        if ext.isEmpty {
            let last = self.lastPathComponent
            let pattern = "^[a-f0-9]{64}$"
            return last.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
        return false
    }
}

