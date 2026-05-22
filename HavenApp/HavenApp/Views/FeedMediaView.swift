import SwiftUI
import AVFoundation
import ImageIO

// MARK: - Media Type Classification

/// Classifies a URL into a media type for rendering decisions.
enum FeedMediaType {
    case photo
    case gif
    case video
    case unknown

    /// Fast classification from file extension alone — no network needed.
    static func fromExtension(_ url: URL) -> FeedMediaType? {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "webp", "heic", "avif", "tiff":
            return .photo
        case "gif":
            return .gif
        case "mp4", "mov", "webm", "m4v":
            return .video
        default:
            return ext.isEmpty ? nil : nil // Unknown extension — need HEAD
        }
    }

    /// Classification from a MIME content-type string.
    static func fromContentType(_ contentType: String) -> FeedMediaType {
        let lower = contentType.lowercased()
        if lower.contains("image/gif") {
            return .gif
        } else if lower.hasPrefix("image/") {
            return .photo
        } else if lower.hasPrefix("video/") {
            return .video
        }
        return .unknown
    }
}

// MARK: - FeedMediaView

/// Unified media rendering component for the feed.
/// Replaces `FeedMediaThumbnail` with proper inline rendering for each media type:
/// - **Photos**: Cached image with aspect ratio preservation and fade-in
/// - **GIFs**: AnimatedImage (native UIImageView/NSImageView) with auto-play
/// - **Videos**: Inline muted autoplay with looping
struct FeedMediaView: View {
    let url: URL
    /// When true, tapping opens the full-screen media viewer.
    var onTap: (() -> Void)? = nil
    /// Maximum height for landscape/square media. Portraits use `portraitMaxHeight`
    /// so they can grow tall enough to fill the available width instead of being
    /// letterboxed inside a landscape container.
    var maxHeight: CGFloat = 400
    /// Maximum height for portrait media. Generous so tall photos/GIFs fill the
    /// full width instead of leaving empty bars on the sides.
    var portraitMaxHeight: CGFloat = 600
    /// Whether this is displayed as a thumbnail in a grid (use square aspect ratio).
    var isThumbnail: Bool = false

    @State private var mediaType: FeedMediaType?
    @State private var isDetecting: Bool = false

    var body: some View {
        Group {
            if let type = mediaType {
                resolvedMediaView(type)
            } else {
                // Still detecting — show shimmer placeholder
                placeholderView
                    .onAppear { detectMediaType() }
            }
        }
    }

    // MARK: - Resolved Views

    @ViewBuilder
    private func resolvedMediaView(_ type: FeedMediaType) -> some View {
        switch type {
        case .gif:
            gifView
        case .video:
            videoView
        case .photo, .unknown:
            photoView
        }
    }

    private var gifView: some View {
        FeedGIFView(
            url: url,
            isThumbnail: isThumbnail,
            landscapeMaxHeight: maxHeight,
            portraitMaxHeight: portraitMaxHeight
        )
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.platformSeparator, lineWidth: 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture { onTap?() }
    }

    private var videoView: some View {
        InlineFeedVideoPlayer(url: url)
            .aspectRatio(1, contentMode: .fill)
            .frame(maxWidth: .infinity)
            .frame(maxHeight: isThumbnail ? .infinity : maxHeight)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.platformSeparator, lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .onTapGesture { onTap?() }
    }

    private var photoView: some View {
        FeedPhotoView(
            url: url,
            isThumbnail: isThumbnail,
            landscapeMaxHeight: maxHeight,
            portraitMaxHeight: portraitMaxHeight
        )
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.platformSeparator, lineWidth: 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture { onTap?() }
    }

    private var placeholderView: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.platformTertiaryGroupedBackground)
            .frame(maxWidth: .infinity)
            .frame(height: isThumbnail ? nil : 200)
            .aspectRatio(isThumbnail ? 1 : nil, contentMode: .fill)
            .overlay(
                ProgressView()
                    .tint(Color.havenPurple.opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.platformSeparator, lineWidth: 0.5)
            )
    }

    // MARK: - Type Detection

    private func detectMediaType() {
        // Fast path: check extension
        if let type = FeedMediaType.fromExtension(url) {
            self.mediaType = type
            return
        }

        // Check cached content type
        if let cached = MediaTypeDetector.shared.getCachedContentType(for: url) {
            self.mediaType = FeedMediaType.fromContentType(cached)
            return
        }

        // Slow path: HTTP HEAD request
        guard !isDetecting else { return }
        isDetecting = true
        MediaTypeDetector.shared.detectContentType(for: url) { detectedType in
            if let detectedType = detectedType {
                self.mediaType = FeedMediaType.fromContentType(detectedType)
            } else {
                self.mediaType = .photo // Fallback to photo
            }
            self.isDetecting = false
        }
    }
}

// MARK: - FeedPhotoView (cached, aspect-preserving)

/// Renders a photo with proper caching and aspect ratio.
///
/// When not in thumbnail mode, the view sizes itself to the image's natural
/// aspect ratio so portrait photos fill the available width instead of being
/// letterboxed inside a square/landscape container. A separate portrait cap
/// keeps extreme aspect ratios from dominating the feed.
private struct FeedPhotoView: View {
    let url: URL
    let isThumbnail: Bool
    var landscapeMaxHeight: CGFloat = 400
    var portraitMaxHeight: CGFloat = 600

    @State private var image: PlatformImage?
    @State private var aspectRatio: CGFloat?
    @State private var isLoading = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.platformTertiaryGroupedBackground)

            if let image = image {
                Image(platformImage: image)
                    .resizable()
                    .aspectRatio(contentMode: isThumbnail ? .fill : .fit)
                    .transition(.opacity.animation(.easeIn(duration: 0.2)))
            } else if isLoading {
                ProgressView()
                    .tint(Color.havenPurple.opacity(0.6))
            }
        }
        .aspectRatio(isThumbnail ? nil : aspectRatio, contentMode: .fit)
        .frame(maxHeight: heightCap)
        .onAppear { loadImage() }
    }

    private var heightCap: CGFloat {
        if isThumbnail { return .infinity }
        guard let ratio = aspectRatio else { return landscapeMaxHeight }
        return ratio < 1 ? portraitMaxHeight : landscapeMaxHeight
    }

    private func loadImage() {
        guard image == nil, !isLoading else { return }
        isLoading = true

        Task {
            if let data = await MediaCacheService.shared.fetchData(url: url) {
                let maxDimension: CGFloat = isThumbnail ? 300 : 800
                if let downsampled = await ImageDownsampler.downsample(data: data, maxDimension: maxDimension) {
                    await MainActor.run {
                        withAnimation(.easeIn(duration: 0.2)) {
                            self.image = downsampled
                            self.aspectRatio = ratioFor(downsampled)
                        }
                        self.isLoading = false
                    }
                } else if let img = PlatformImage(data: data) {
                    await MainActor.run {
                        withAnimation(.easeIn(duration: 0.2)) {
                            self.image = img
                            self.aspectRatio = ratioFor(img)
                        }
                        self.isLoading = false
                    }
                } else {
                    await MainActor.run { self.isLoading = false }
                }
            } else {
                await MainActor.run { self.isLoading = false }
            }
        }
    }

    private func ratioFor(_ img: PlatformImage) -> CGFloat? {
        let size = img.size
        guard size.width > 0, size.height > 0 else { return nil }
        return size.width / size.height
    }
}

// MARK: - FeedGIFView (cached, aspect-preserving)

/// Renders a GIF with proper caching, auto-play, and aspect ratio.
private struct FeedGIFView: View {
    let url: URL
    let isThumbnail: Bool
    var landscapeMaxHeight: CGFloat = 400
    var portraitMaxHeight: CGFloat = 600

    @State private var aspectRatio: CGFloat?
    @State private var isLoading = true

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.platformTertiaryGroupedBackground)

            AnimatedImage(
                url: url,
                contentMode: isThumbnail ? .fill : .fit,
                shouldAnimate: true,
                onLoad: { size in
                    withAnimation(.easeIn(duration: 0.2)) {
                        if size.width > 0 && size.height > 0 {
                            self.aspectRatio = size.width / size.height
                        }
                        self.isLoading = false
                    }
                }
            )
            .opacity(isLoading ? 0 : 1)

            if isLoading {
                ProgressView()
                    .tint(Color.havenPurple.opacity(0.6))
            }
        }
        .aspectRatio(isThumbnail ? nil : aspectRatio, contentMode: .fit)
        .frame(maxHeight: heightCap)
    }

    private var heightCap: CGFloat {
        if isThumbnail { return .infinity }
        guard let ratio = aspectRatio else { return landscapeMaxHeight }
        return ratio < 1 ? portraitMaxHeight : landscapeMaxHeight
    }
}
