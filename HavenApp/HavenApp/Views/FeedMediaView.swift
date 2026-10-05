import SwiftUI
import AVFoundation
import ImageIO

// MARK: - Media Type Classification

/// Classifies a URL into a media type for rendering decisions.
enum FeedMediaType {
    case photo
    case gif
    case video
    case audio
    case unknown

    /// Fast classification from file extension alone — no network needed.
    static func fromExtension(_ url: URL) -> FeedMediaType? {
        let ext = url.pathExtension.lowercased()
        if ext == "gif" { return .gif }
        if SupportedMediaFormats.imageExtensions.contains(ext) { return .photo }
        if SupportedMediaFormats.videoExtensions.contains(ext) { return .video }
        if SupportedMediaFormats.audioExtensions.contains(ext) { return .audio }
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
        case .audio: self = .audio
        case .unknown: self = .unknown
        }
    }
}

// MARK: - FeedMediaView

/// Unified media rendering component for the feed.
/// Replaces `FeedMediaThumbnail` with proper inline rendering for each media type:
/// - **Photos**: Cached image with aspect ratio preservation and fade-in
/// - **GIFs**: AnimatedImage (native UIImageView/NSImageView) with auto-play
/// - **Videos**: Inline muted autoplay with looping
/// - **Audio**: A play card on the app-wide player
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
    /// Plays a GIF thumbnail instead of showing its first frame. For a single
    /// thumbnail beside a line of text; grids stay still.
    var animatesThumbnail: Bool = false
    /// Fills the frame it is given edge to edge, cropping if it must (a
    /// carousel page), instead of fitting with empty space around it.
    var fillsFrame: Bool = false

    @ObservedObject private var configService = ConfigService.shared
    @Environment(\.mediaZoomNamespace) private var zoomNamespace
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
        case .audio:
            // Plays in place; there is nothing for the media viewer to show.
            FeedAudioCard(url: url, isThumbnail: isThumbnail)
        case .photo, .unknown:
            photoView
        }
    }

    private var gifView: some View {
        FeedGIFView(
            url: url,
            isThumbnail: isThumbnail,
            animatesThumbnail: animatesThumbnail,
            landscapeMaxHeight: maxHeight,
            portraitMaxHeight: portraitMaxHeight
        )
        .frame(maxWidth: .infinity)
        .mediaFrame(isThumbnail: isThumbnail)
        .onTapGestureIfSome(onTap)
        .mediaZoomSource(url, namespace: onTap == nil ? nil : zoomNamespace)
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
                .aspectRatio(isThumbnail ? 1 : videoAspectRatio ?? hintAspectRatio, contentMode: isThumbnail ? .fill : .fit)
            } else {
                InlineFeedVideoPlayer(
                    url: url,
                    onTap: onTap,
                    onAspectRatio: { ratio in if ratio > 0 { videoAspectRatio = ratio } }
                )
                .aspectRatio(isThumbnail ? 1 : videoAspectRatio ?? hintAspectRatio, contentMode: isThumbnail ? .fill : .fit)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: isThumbnail ? .infinity : videoHeightCap)
        .mediaFrame(isThumbnail: isThumbnail)
        .onTapGestureIfSome(onTap)
        .mediaZoomSource(url, namespace: onTap == nil ? nil : zoomNamespace)
    }

    /// Height cap for inline video, mirroring `FeedPhotoView`: portraits get a
    /// taller cap so they fill the width; defaults to the landscape cap until
    /// the video's dimensions are known.
    private var videoHeightCap: CGFloat {
        guard let ratio = videoAspectRatio ?? hintAspectRatio else { return maxHeight }
        return ratio < 1 ? portraitMaxHeight : maxHeight
    }

    private var photoView: some View {
        FeedPhotoView(
            url: url,
            isThumbnail: isThumbnail,
            fillsFrame: fillsFrame,
            landscapeMaxHeight: maxHeight,
            portraitMaxHeight: portraitMaxHeight
        )
        .frame(maxWidth: .infinity)
        .mediaFrame(isThumbnail: isThumbnail)
        .onTapGestureIfSome(onTap)
        .mediaZoomSource(url, namespace: onTap == nil ? nil : zoomNamespace)
    }

    /// Aspect ratio the note published in its `imeta` `dim`, if any.
    private var hintAspectRatio: CGFloat? {
        MediaHints.shared.hint(for: url)?.aspectRatio
    }

    @ViewBuilder
    private var placeholderView: some View {
        if !isThumbnail, let ratio = hintAspectRatio {
            // Reserve the media's real shape so the row doesn't resize when
            // the type resolves and the image lands.
            placeholderShape
                .aspectRatio(ratio, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .frame(maxHeight: ratio < 1 ? portraitMaxHeight : maxHeight)
        } else {
            placeholderShape
                .frame(maxWidth: .infinity)
                .frame(height: isThumbnail ? nil : 200)
                .aspectRatio(isThumbnail ? 1 : nil, contentMode: .fill)
        }
    }

    private var placeholderShape: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.platformTertiaryGroupedBackground)
            .overlay(MediaLoadingPlaceholder(url: url, isLoading: true))
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
    var fillsFrame: Bool = false
    var landscapeMaxHeight: CGFloat = 400
    var portraitMaxHeight: CGFloat = 600

    @State private var image: PlatformImage?
    @State private var aspectRatio: CGFloat?
    @State private var isLoading = false

    var body: some View {
        ZStack {
            // Grey only behind a thumbnail, or while a photo is loading.
            if isThumbnail || image == nil {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.platformTertiaryGroupedBackground)
            }

            if let image = image {
                Image(platformImage: image)
                    .resizable()
                    .aspectRatio(contentMode: isThumbnail || fillsFrame ? .fill : .fit)
                    .transition(.opacity.animation(Motion.media))
            } else {
                MediaLoadingPlaceholder(url: url, isLoading: isLoading)
                    .transition(MediaLoadingPlaceholder.removal)
            }
        }
        .aspectRatio(isThumbnail || fillsFrame ? nil : displayAspectRatio, contentMode: .fit)
        .frame(maxHeight: fillsFrame ? .infinity : heightCap)
        .clipped()
        .onAppear {
            MediaCacheService.shared.setDownloadPriority(.normal, for: url)
            loadImage()
        }
        .onDisappear {
            // Scrolled away before it loaded: let on-screen photos go first.
            if image == nil { MediaCacheService.shared.setDownloadPriority(.low, for: url) }
        }
    }

    /// The decoded image's ratio, or the note's `imeta` `dim` until it lands,
    /// so the row is already the right height when the pixels arrive.
    private var displayAspectRatio: CGFloat? {
        aspectRatio ?? Self.knownRatios[url] ?? MediaHints.shared.hint(for: url)?.aspectRatio
    }

    /// Ratios of photos already decoded this session. A row that scrolls off
    /// and back comes back as a new view; without this it opened at the
    /// placeholder height and snapped to the photo's shape again, moving
    /// everything below it.
    @MainActor private static var knownRatios: [URL: CGFloat] = [:]

    private var heightCap: CGFloat {
        if isThumbnail { return .infinity }
        guard let ratio = displayAspectRatio else { return landscapeMaxHeight }
        return ratio < 1 ? portraitMaxHeight : landscapeMaxHeight
    }

    private func loadImage() {
        guard image == nil, !isLoading else { return }

        // Fast path: check in-memory decoded image cache (no disk I/O)
        if let cached = MediaCacheService.shared.cachedImage(for: url) {
            self.image = cached
            self.aspectRatio = ratioFor(cached); Self.knownRatios[url] = self.aspectRatio
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
                        self.aspectRatio = ratioFor(downsampled); Self.knownRatios[url] = self.aspectRatio
                        self.isLoading = false
                    }
                } else if let img = PlatformImage(data: data) {
                    MediaCacheService.shared.cacheImage(img, for: url)
                    await MainActor.run {
                        self.image = img
                        self.aspectRatio = ratioFor(img); Self.knownRatios[url] = self.aspectRatio
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
    var animatesThumbnail: Bool = false
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
                shouldAnimate: !isThumbnail || animatesThumbnail,
                targetSize: isThumbnail && animatesThumbnail ? CGSize(width: 80, height: 80) : nil,
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
                MediaLoadingPlaceholder(url: url, isLoading: true)
                    .transition(MediaLoadingPlaceholder.removal)
            }
        }
        // A thumbnail fills the square its caller gives it. A nil ratio would
        // fit the image's own shape and letterbox a wide GIF inside the square.
        .aspectRatio(isThumbnail ? 1 : displayAspectRatio, contentMode: isThumbnail ? .fill : .fit)
        .frame(maxHeight: heightCap)
    }

    private var displayAspectRatio: CGFloat? {
        aspectRatio ?? MediaHints.shared.hint(for: url)?.aspectRatio
    }

    private var heightCap: CGFloat {
        if isThumbnail { return .infinity }
        guard let ratio = displayAspectRatio else { return landscapeMaxHeight }
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

// MARK: - Loading placeholder

/// What a photo shows before its pixels arrive. With a NIP-92 `blurhash` it is
/// a blurred preview of the image; without one it is the plain card fill, and
/// a spinner appears only if the load is still going after 0.6s, so an image
/// that lands quickly never flashes a spinner first.
private struct MediaLoadingPlaceholder: View {
    let url: URL
    let isLoading: Bool

    @State private var spinnerDue = false

    /// Stay under the arriving image until its fade has finished; dropping the
    /// preview at once would flash the empty card between the two.
    static var removal: AnyTransition {
        .asymmetric(insertion: .identity, removal: .opacity.animation(Motion.media.delay(0.18)))
    }

    var body: some View {
        if let preview = BlurHashDecoder.image(for: MediaHints.shared.hint(for: url)?.blurhash) {
            Image(decorative: preview, scale: 1)
                .resizable()
                .interpolation(.medium)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
        } else if isLoading {
            ZStack {
                if spinnerDue {
                    ProgressView()
                        .tint(Color.havenPurple.opacity(0.6))
                        .transition(.opacity.animation(Motion.fade))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task {
                try? await Task.sleep(for: .milliseconds(600))
                spinnerDue = true
            }
        }
    }
}

// MARK: - BlurHash

/// Decodes a BlurHash (https://blurha.sh) into a small CGImage that SwiftUI
/// scales up. Kept in this file rather than its own so the change does not
/// regenerate the Xcode project under two other open feed PRs.
enum BlurHashDecoder {
    /// Output is always 32x32: a blurhash has at most 9x9 components, so more
    /// pixels add nothing once it is stretched to the card.
    private static let side = 32

    private static let cache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.countLimit = 500
        return cache
    }()

    static func image(for hash: String?) -> CGImage? {
        guard let hash, !hash.isEmpty else { return nil }
        if let cached = cache.object(forKey: hash as NSString) { return cached }
        guard let image = decode(hash) else { return nil }
        cache.setObject(image, forKey: hash as NSString)
        return image
    }

    private static let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#$%*+,-.:;=?@[]^_{|}~")
    private static let digit: [Character: Int] = Dictionary(uniqueKeysWithValues: alphabet.enumerated().map { ($1, $0) })

    private static func decode83(_ s: Substring) -> Int? {
        var value = 0
        for ch in s {
            guard let d = digit[ch] else { return nil }
            value = value * 83 + d
        }
        return value
    }

    private static func sRGBToLinear(_ v: Int) -> Float {
        let x = Float(v) / 255
        return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
    }

    private static func linearToSRGB(_ v: Float) -> UInt8 {
        let x = max(0, min(1, v))
        let s = x <= 0.0031308 ? x * 12.92 : 1.055 * pow(x, 1 / 2.4) - 0.055
        return UInt8(max(0, min(255, (s * 255 + 0.5).rounded(.down))))
    }

    private static func signPow(_ v: Float, _ e: Float) -> Float {
        copysign(pow(abs(v), e), v)
    }

    static func decode(_ hash: String) -> CGImage? {
        let chars = Array(hash)
        guard chars.count >= 6, let sizeFlag = decode83(Substring(String(chars[0]))) else { return nil }
        let nx = sizeFlag % 9 + 1
        let ny = sizeFlag / 9 + 1
        guard chars.count == 4 + 2 * nx * ny,
              let quantMax = decode83(Substring(String(chars[1]))) else { return nil }
        let maxAC = Float(quantMax + 1) / 166

        func sub(_ from: Int, _ len: Int) -> Substring { Substring(String(chars[from..<(from + len)])) }

        var colors: [(Float, Float, Float)] = []
        colors.reserveCapacity(nx * ny)
        guard let dc = decode83(sub(2, 4)) else { return nil }
        colors.append((sRGBToLinear(dc >> 16), sRGBToLinear((dc >> 8) & 255), sRGBToLinear(dc & 255)))
        for i in 1..<(nx * ny) {
            guard let ac = decode83(sub(4 + i * 2, 2)) else { return nil }
            let r = ac / (19 * 19), g = (ac / 19) % 19, b = ac % 19
            colors.append((
                signPow((Float(r) - 9) / 9, 2) * maxAC,
                signPow((Float(g) - 9) / 9, 2) * maxAC,
                signPow((Float(b) - 9) / 9, 2) * maxAC
            ))
        }

        let n = side
        var pixels = [UInt8](repeating: 255, count: n * n * 4)
        // Basis cosines are separable: precompute each axis once.
        let cosX = (0..<nx).map { i in (0..<n).map { x in cos(Float.pi * Float(x * i) / Float(n)) } }
        let cosY = (0..<ny).map { j in (0..<n).map { y in cos(Float.pi * Float(y * j) / Float(n)) } }
        for y in 0..<n {
            for x in 0..<n {
                var r: Float = 0, g: Float = 0, b: Float = 0
                for j in 0..<ny {
                    let cy = cosY[j][y]
                    for i in 0..<nx {
                        let basis = cosX[i][x] * cy
                        let c = colors[i + j * nx]
                        r += c.0 * basis; g += c.1 * basis; b += c.2 * basis
                    }
                }
                let o = (y * n + x) * 4
                pixels[o] = linearToSRGB(r)
                pixels[o + 1] = linearToSRGB(g)
                pixels[o + 2] = linearToSRGB(b)
            }
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }
}

// MARK: - FeedAudioCard

/// An audio file shared in a post (an MP3 link, or a Blossom blob that turns
/// out to be audio): a play button on the app-wide player, so it keeps going
/// in the mini player and on the lock screen like a Wavlake song.
struct FeedAudioCard: View {
    let url: URL
    /// A grid or one-line thumbnail: just the audio glyph, no controls.
    var isThumbnail: Bool = false
    @ObservedObject private var player = MusicPlayerService.shared

    private var title: String {
        let name = url.deletingPathExtension().lastPathComponent.removingPercentEncoding
            ?? url.deletingPathExtension().lastPathComponent
        // A Blossom hash, or no file name at all, says nothing to a person.
        let isHash = name.count == 64 && name.allSatisfy(\.isHexDigit)
        return name.isEmpty || name == "/" || isHash ? "Audio" : name
    }

    private var track: PlayerTrack {
        PlayerTrack(id: url.absoluteString, title: title, artist: url.host ?? "",
                    artworkURL: nil, audioURL: url, duration: nil)
    }

    var body: some View {
        if isThumbnail {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.platformTertiaryGroupedBackground)
                .overlay(Image(systemName: "waveform").font(.appSystem(size: 22)).foregroundColor(.secondary))
                .accessibilityLabel("Audio")
        } else {
            card
        }
    }

    private var card: some View {
        let isCurrent = player.current?.id == url.absoluteString
        return HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.havenPurple.opacity(0.15))
                .frame(width: 52, height: 52)
                .overlay(Image(systemName: "waveform").font(.appSystem(size: 22)).foregroundColor(.havenPurple))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.appSystem(size: 15, weight: .semibold)).lineLimit(1)
                if let host = url.host {
                    Text(host).font(.appSystem(size: 13)).foregroundColor(.secondary).lineLimit(1)
                }
                Label(url.pathExtension.isEmpty ? "Audio" : url.pathExtension.uppercased(), systemImage: "music.note")
                    .font(.appSystem(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 8)
            Button {
                if isCurrent { player.togglePlayPause() } else { player.play(tracks: [track]) }
            } label: {
                Image(systemName: isCurrent && player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.appSystem(size: 38))
                    .foregroundColor(.havenPurple)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isCurrent && player.isPlaying ? "Pause \(title)" : "Play \(title)")
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.1)))
    }
}

private extension View {
    /// Full-size media in a post runs square to its edges, with no rounded
    /// frame, border or grey box (Logen: screen room). Grid and one-line
    /// thumbnails keep their rounded tile.
    @ViewBuilder
    func mediaFrame(isThumbnail: Bool) -> some View {
        if isThumbnail {
            self.clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.platformSeparator, lineWidth: 0.5))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        } else {
            self.clipped().contentShape(Rectangle())
        }
    }
}
