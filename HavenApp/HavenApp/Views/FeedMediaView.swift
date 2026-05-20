import SwiftUI
import AVFoundation

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
    /// Maximum height for the media view. Defaults to 400.
    var maxHeight: CGFloat = 400
    /// Whether this is displayed as a thumbnail in a grid (use square aspect ratio).
    var isThumbnail: Bool = false

    @State private var mediaType: FeedMediaType?
    @State private var isDetecting: Bool = false
    @State private var gifAspectRatio: CGFloat? = nil

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
        Group {
            if isThumbnail {
                AnimatedImage(url: url, contentMode: .fill, shouldAnimate: true,
                              targetSize: CGSize(width: 300, height: 300))
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: .infinity)
            } else {
                AnimatedImage(url: url, contentMode: .fill, shouldAnimate: true,
                              onLoad: { size in
                                  guard size.width > 0, size.height > 0 else { return }
                                  gifAspectRatio = size.width / size.height
                              })
                    .aspectRatio(gifAspectRatio ?? 16.0 / 9.0, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: maxHeight)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.platformSeparator, lineWidth: 0.5))
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
        FeedPhotoView(url: url, isThumbnail: isThumbnail)
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
private struct FeedPhotoView: View {
    let url: URL
    let isThumbnail: Bool

    @State private var image: PlatformImage?
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
        .onAppear { loadImage() }
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
                        }
                        self.isLoading = false
                    }
                } else if let img = PlatformImage(data: data) {
                    await MainActor.run {
                        withAnimation(.easeIn(duration: 0.2)) {
                            self.image = img
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
}
