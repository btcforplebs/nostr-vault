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
        if ext == "gif" { return .gif }
        if SupportedMediaFormats.imageExtensions.contains(ext) { return .photo }
        if SupportedMediaFormats.videoExtensions.contains(ext) { return .video }
        return ext.isEmpty ? nil : nil // Unknown extension — need HEAD
    }

    /// Classification from a MIME content-type string.
    static func fromContentType(_ contentType: String) -> FeedMediaType {
        FeedMediaType(MediaKindResolver.kind(fromMime: contentType))
    }

    init(_ kind: MediaKind) {
        switch kind {
        case .video: self = .video
        case .gif: self = .gif
        case .image: self = .photo
        case .audio, .unknown: self = .unknown
        }
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

    @ObservedObject private var configService = ConfigService.shared
    @State private var mediaType: FeedMediaType?
    @State private var isDetecting: Bool = false
    @State private var videoAspectRatio: CGFloat?

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
        .onTapGestureIfSome(onTap)
    }

    private var videoView: some View {
        Group {
            if isThumbnail || !configService.config.autoplayVideos {
                // In condensed/thumbnail contexts, never autoload the full video just
                // to make a small still — extract the frame from the remote asset
                // instead of downloading the whole file.
                FeedVideoThumbnailView(
                    url: url,
                    showPlayOverlay: !isThumbnail,
                    avoidFullDownload: isThumbnail,
                    onAspectRatio: { ratio in if ratio > 0 { videoAspectRatio = ratio } }
                )
                .aspectRatio(isThumbnail ? 1 : videoAspectRatio, contentMode: isThumbnail ? .fill : .fit)
            } else {
                InlineFeedVideoPlayer(
                    url: url,
                    onTap: onTap,
                    onAspectRatio: { ratio in if ratio > 0 { videoAspectRatio = ratio } }
                )
                .aspectRatio(isThumbnail ? 1 : videoAspectRatio, contentMode: isThumbnail ? .fill : .fit)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: isThumbnail ? .infinity : videoHeightCap)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.platformSeparator, lineWidth: 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGestureIfSome(onTap)
    }

    /// Height cap for inline video, mirroring `FeedPhotoView`: portraits get a
    /// taller cap so they fill the width; defaults to the landscape cap until
    /// the video's dimensions are known.
    private var videoHeightCap: CGFloat {
        guard let ratio = videoAspectRatio else { return maxHeight }
        return ratio < 1 ? portraitMaxHeight : maxHeight
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
        .onTapGestureIfSome(onTap)
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
        // Fast path: extension / MIME hint / detector cache — no network.
        if let kind = MediaKindResolver.cachedKind(for: url) {
            self.mediaType = FeedMediaType(kind)
            return
        }

        // Slow path: HTTP HEAD request (+ magic-byte sniff for octet-stream servers)
        guard !isDetecting else { return }
        isDetecting = true
        Task { @MainActor in
            let kind = await MediaKindResolver.kind(for: url)
            // Unknown resolves to photo — the historical fallback.
            self.mediaType = kind == .unknown ? .photo : FeedMediaType(kind)
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
                    .transition(.opacity.animation(Motion.media))
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

        // Fast path: check in-memory decoded image cache (no disk I/O)
        if let cached = MediaCacheService.shared.cachedImage(for: url) {
            self.image = cached
            self.aspectRatio = ratioFor(cached)
            return
        }

        isLoading = true

        Task {
            if let data = await MediaCacheService.shared.fetchData(url: url) {
                let maxDimension: CGFloat = isThumbnail ? 300 : 800
                if let downsampled = await ImageDownsampler.downsample(data: data, maxDimension: maxDimension) {
                    MediaCacheService.shared.cacheImage(downsampled, for: url)
                    await MainActor.run {
                        // No `withAnimation`: the row must take its final
                        // height in one frame. Animating `aspectRatio` grew
                        // the row over 0.18s and slid every post below it
                        // mid-scroll. The image's own `.transition` still
                        // fades the pixels in.
                        self.image = downsampled
                        self.aspectRatio = ratioFor(downsampled)
                        self.isLoading = false
                    }
                } else if let img = PlatformImage(data: data) {
                    MediaCacheService.shared.cacheImage(img, for: url)
                    await MainActor.run {
                        self.image = img
                        self.aspectRatio = ratioFor(img)
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
                shouldAnimate: !isThumbnail,
                onLoad: { size in
                    // Unanimated, as in FeedPhotoView: resize the row at
                    // once and animate only the opacity below.
                    if size.width > 0 && size.height > 0 {
                        self.aspectRatio = size.width / size.height
                    }
                    self.isLoading = false
                }
            )
            .animation(Motion.media) { $0.opacity(isLoading ? 0 : 1) }

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

// MARK: - FeedVideoThumbnailView

private struct FeedVideoThumbnailView: View {
    let url: URL
    var showPlayOverlay: Bool = false
    /// When true, the preview frame is extracted from the remote asset via
    /// byte-range requests instead of downloading the entire video first. Used by
    /// condensed views so scrolling past a video never autoloads it.
    var avoidFullDownload: Bool = false
    /// Reports the extracted frame's aspect ratio (width / height) once known,
    /// so the container can size the video to its natural shape.
    var onAspectRatio: ((CGFloat) -> Void)? = nil
    @State private var thumbnail: PlatformImage? = nil
    @State private var loadFailed = false

    var body: some View {
        ZStack {
            Color.platformTertiaryGroupedBackground

            if let thumb = thumbnail {
                Image(platformImage: thumb)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity.animation(Motion.media))
            } else if loadFailed {
                // Couldn't extract a frame without a full download — show a video
                // glyph rather than spinning forever.
                Image(systemName: "video.fill")
                    .font(.appSystem(size: 22))
                    .foregroundColor(Color.havenPurple.opacity(0.5))
            } else {
                ProgressView()
                    .tint(Color.havenPurple.opacity(0.6))
            }

            if showPlayOverlay && thumbnail != nil {
                Image(systemName: "play.circle.fill")
                    .font(.appSystem(size: 44))
                    .foregroundColor(.white.opacity(0.85))
                    .shadow(color: .black.opacity(0.5), radius: 4)
            }
        }
        .onAppear { loadThumbnail() }
    }

    private func loadThumbnail() {
        if let cached = MediaCacheService.shared.cachedThumbnail(for: url) {
            self.thumbnail = cached
            reportAspect(cached)
            return
        }
        Task {
            let thumb = await MediaCacheService.shared.generateThumbnail(for: url, allowFullDownload: !avoidFullDownload)
            await MainActor.run {
                if let thumb = thumb {
                    self.thumbnail = thumb
                    reportAspect(thumb)
                } else {
                    self.loadFailed = true
                }
            }
        }
    }

    private func reportAspect(_ image: PlatformImage) {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return }
        onAspectRatio?(size.width / size.height)
    }
}

// MARK: - View Extension

extension View {
    @ViewBuilder
    func onTapGestureIfSome(_ action: (() -> Void)?) -> some View {
        if let action = action {
            self.highPriorityGesture(TapGesture().onEnded { action() })
        } else {
            self
        }
    }
}
