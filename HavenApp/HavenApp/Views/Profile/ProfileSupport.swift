import SwiftUI
import Combine
import ImageIO

// MARK: - Articles, diVines and music by one person

/// Loads one person's articles (kind 30023) and diVines (kind 34236) from the
/// relays the profile already reads, plus diVine's own relay, and their music
/// from Wavlake. Wavlake can only be matched to a key through an artist's own
/// page, so music is found among the artists in recent rankings and the ones
/// you've played: a musician nobody has played lately has no Music tab yet.
@MainActor
final class ProfileExtrasLoader: ObservableObject {
    @Published private(set) var articles: [FeedNote] = []
    @Published private(set) var reels: [Reel] = []
    @Published private(set) var tracks: [WavlakeTrack] = []
    /// True until both the events and the music lookups have answered.
    @Published private(set) var isLoading = false
    private var loadedPubkey: String?
    private var generation = 0

    /// `force` fetches again for the person already shown, keeping their
    /// tabs on screen until the new answers replace them.
    func load(pubkey: String, relays: [URL], force: Bool = false) {
        if loadedPubkey == pubkey {
            guard force else { return }
        } else {
            articles = []; reels = []; tracks = []
        }
        loadedPubkey = pubkey
        generation += 1
        let thisLoad = generation
        isLoading = true
        Task {
            async let events: Void = loadEvents(pubkey: pubkey, relays: relays)
            async let music: Void = loadMusic(pubkey: pubkey)
            _ = await (events, music)
            if generation == thisLoad { isLoading = false }
        }
    }

    private func loadEvents(pubkey: String, relays: [URL]) async {
        let filters: [[String: Any]] = [
            ["kinds": [30023], "authors": [pubkey], "limit": 100],
            ["kinds": ReelsFeedService.videoKinds, "authors": [pubkey], "limit": 100],
        ]
        let events = await ZapHistoryService.query(filters: filters, relays: relays, timeout: 8)
        guard loadedPubkey == pubkey else { return }
        // No answer at all on a refresh is a failed fetch, not proof the tabs
        // are empty; keep what is shown.
        if events.isEmpty, !(articles.isEmpty && reels.isEmpty) { return }
        let notes: [FeedNote] = events.compactMap { event in
            guard let id = event["id"] as? String, (event["pubkey"] as? String) == pubkey,
                  let kind = event["kind"] as? Int, let tags = event["tags"] as? [[String]],
                  let created = (event["created_at"] as? NSNumber)?.doubleValue else { return nil }
            return FeedNote(id: id, pubkey: pubkey, content: event["content"] as? String ?? "",
                            createdAt: Date(timeIntervalSince1970: created), tags: tags, kind: kind)
        }
        // Addressable: keep the newest version of each, newest first.
        articles = FeedFilterEngine.dedupeAddressable(notes.filter { $0.kind == 30023 })
        var seenVideos = Set<URL>()
        reels = FeedFilterEngine.dedupeAddressable(notes.filter { ReelsFeedService.videoKinds.contains($0.kind) })
            .compactMap { Reel(note: $0, createdAt: Int64($0.createdAt.timeIntervalSince1970)) }
            .filter { seenVideos.insert($0.videoURL).inserted }
            .sorted(by: Reel.newestFirst)
    }

    private func loadMusic(pubkey: String) async {
        let (artists, _) = await MusicFeedState.shared.followedArtists(follows: [pubkey])
        guard loadedPubkey == pubkey, let artist = artists.first,
              let page = await MusicFeedState.shared.artistPage(artist.id) else { return }
        guard loadedPubkey == pubkey else { return }
        tracks = page.tracks
    }
}

// MARK: - Feed changes the profile shows

/// Redraws the profile for the main-feed state it reads: who you follow,
/// your likes, reactions, reposts and zaps on its notes, and fetched
/// originals of reposted or replied-to notes. Not for the feed's own notes,
/// paging or connection state, which change constantly and are not shown.
@MainActor
final class ProfileFeedWatch: ObservableObject {
    private var cancellable: AnyCancellable?

    init() {
        let feed = FeedService.shared
        // dropFirst: each @Published sends its current value on subscribe.
        let changes: [AnyPublisher<Void, Never>] = [
            feed.$followedPubkeys.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            feed.$likedEventIds.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            feed.$myReactions.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            feed.$repostedEventIds.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            feed.$zappedEventIds.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            feed.$parentNotesCache.dropFirst().map { _ in () }.eraseToAnyPublisher(),
        ]
        // @Published fires before the value is stored; the throttle delivers
        // on the next run loop pass, after it is. The first change in a burst
        // goes through at once, so a like still shows straight away.
        cancellable = Publishers.MergeMany(changes)
            .throttle(for: .milliseconds(150), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] in self?.objectWillChange.send() }
    }
}

// MARK: - Profile banner

/// The strip across the top of a profile. Runs edge to edge and up under the
/// navigation bar, scrolls with the page, and fades into the page at the
/// bottom. Until the banner arrives, or when there is none, a wash tinted from
/// the profile picture stands in so the header never jumps or sits empty.
struct ProfileBannerView: View {
    let bannerURL: URL?
    let avatarURL: URL?
    let pubkey: String
    let height: CGFloat
    let topInset: CGFloat
    let onTap: (URL) -> Void

    @State private var image: PlatformImage?
    @State private var tint: Color?

    var body: some View {
        // Up under the navigation bar, then scrolls with the page like any
        // other row. No stretch on pull: the pull opens plain space above it,
        // where the refresh spinner shows. The wash sets the size and the
        // image fills it as an overlay, so a wide banner cannot widen the page.
        wash
            .frame(height: height + topInset)
            .overlay {
                if let image {
                    Image(platformImage: image)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                }
            }
            .clipped()
            .overlay(alignment: .top) {
                // Keeps the toolbar buttons and close button legible on a
                // bright banner.
                LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: topInset + 56)
            }
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [.clear, Color.platformWindowBackground], startPoint: .top, endPoint: .bottom)
                    .frame(height: height * 0.45)
            }
            .padding(.top, -topInset)
            .contentShape(Rectangle())
            .onTapGesture {
                if image != nil, let bannerURL { onTap(bannerURL) }
            }
            .accessibilityElement()
            .accessibilityLabel(image != nil ? "Profile banner" : "")
            .accessibilityAddTraits(image != nil ? .isButton : [])
            .accessibilityHidden(image == nil)
            .task(id: bannerURL) { await loadBanner() }
            .task(id: avatarURL) { await loadTint() }
    }

    private var wash: some View {
        let base = tint ?? ProfileBannerView.fallbackTint(pubkey)
        return LinearGradient(
            colors: [base.opacity(0.9), base.opacity(0.35)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func loadBanner() async {
        guard let url = bannerURL else { image = nil; return }
        if let cached = BannerImageCache.shared.image(for: url) {
            image = cached
            return
        }
        image = nil
        guard let loaded = await BannerImageCache.shared.load(url: url), !Task.isCancelled else { return }
        withAnimation(Motion.media) { image = loaded }
    }

    private func loadTint() async {
        guard let url = avatarURL else { tint = nil; return }
        guard let average = await BannerImageCache.shared.averageColor(ofCachedImageAt: url),
              !Task.isCancelled else { return }
        // A picture with no real color takes the app accent.
        withAnimation(Motion.fade) { tint = average ?? .havenPurple }
    }

    /// The same hue the letter avatar uses, for profiles with no picture yet.
    static func fallbackTint(_ pubkey: String) -> Color {
        let first = pubkey.unicodeScalars.first?.value ?? 200
        return Color(hue: Double(first % 360) / 360.0, saturation: 0.55, brightness: 0.6)
    }
}

/// Banner images, downsampled to screen size (banners are often several
/// thousand pixels wide), and avatar tints. Disk caching is MediaCacheService's.
private final class BannerImageCache: @unchecked Sendable {
    static let shared = BannerImageCache()

    private let images = NSCache<NSURL, PlatformImage>()
    private let tints = NSCache<NSURL, ColorBox>()
    private final class ColorBox { let color: Color?; init(_ c: Color?) { color = c } }

    private static let targetPixelSize: CGFloat = 2048

    init() {
        images.countLimit = 24
        tints.countLimit = 300
    }

    func image(for url: URL) -> PlatformImage? {
        images.object(forKey: url as NSURL)
    }

    func load(url: URL) async -> PlatformImage? {
        if let cached = image(for: url) { return cached }
        if MediaCacheService.shared.isKnown404(url: url) { return nil }
        var data = MediaCacheService.shared.loadFromCache(url: url)
        if data == nil,
           let (fetched, response) = try? await MediaSessionService.shared.session.data(from: url),
           let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
            MediaCacheService.shared.saveToCache(url: url, data: fetched)
            data = fetched
        }
        guard let data, let img = Self.downsample(data, maxPixel: Self.targetPixelSize) else { return nil }
        images.setObject(img, forKey: url as NSURL)
        return img
    }

    /// The average color of an avatar the app has already downloaded. Never
    /// fetches: the avatar view does that, and a tint is not worth a request.
    /// nil when the avatar isn't on disk; `.some(nil)` when it has no real color.
    func averageColor(ofCachedImageAt url: URL) async -> Color?? {
        if let box = tints.object(forKey: url as NSURL) { return box.color }
        // Avatars keep only their small copy on disk; an older install may
        // still hold the original.
        guard let data = AvatarImageCache.shared.smallCopyData(of: url) ?? MediaCacheService.shared.loadFromCache(url: url),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 16
              ] as CFDictionary) else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(thumb, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let color = Self.washColor(r: Double(pixel[0]) / 255, g: Double(pixel[1]) / 255, b: Double(pixel[2]) / 255)
        tints.setObject(ColorBox(color), forKey: url as NSURL)
        return color
    }

    /// A picture's average is usually a muddy dark gray. Keep its hue but give
    /// it enough color and light to read as a tint; a picture with no real
    /// color gives nil.
    private static func washColor(r: Double, g: Double, b: Double) -> Color? {
        let maxC = max(r, g, b), minC = min(r, g, b)
        let delta = maxC - minC
        let saturation = maxC > 0 ? delta / maxC : 0
        guard saturation > 0.15, delta > 0 else { return nil }
        var hue: Double
        if maxC == r { hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
        else if maxC == g { hue = (b - r) / delta + 2 }
        else { hue = (r - g) / delta + 4 }
        hue = (hue / 6 + 1).truncatingRemainder(dividingBy: 1)
        return Color(hue: hue, saturation: min(max(saturation, 0.45), 0.8), brightness: min(max(maxC, 0.5), 0.75))
    }

    private static func downsample(_ data: Data, maxPixel: CGFloat) -> PlatformImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceShouldCacheImmediately: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixel
              ] as CFDictionary) else { return nil }
        #if canImport(AppKit)
        return NSImage(cgImage: cg, size: .zero)
        #else
        return UIImage(cgImage: cg)
        #endif
    }
}

/// Chips left to right, wrapping to a new line when the next one does not
/// fit. A chip wider than the row is held to the row and truncates.
struct ProfileChipFlow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = Self.size(of: subview, in: width)
            if x + size.width > width && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = Self.size(of: subview, in: bounds.width)
            if x + size.width > bounds.maxX && x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .init(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }

    private static func size(of subview: LayoutSubview, in width: CGFloat) -> CGSize {
        subview.sizeThatFits(ProposedViewSize(width: width.isFinite ? width : nil, height: nil))
    }
}

/// Notes received by the profile's stream and waiting to go on screen. A
/// reference, so adding to it does not redraw the page.
final class PendingProfileNotes {
    var notes: [FeedNote] = []
    var tagged: [FeedNote] = []
    var scheduled = false
}

/// The profile's notes split by tab.
struct ProfileNoteBuckets {
    var top: [FeedNote] = []
    var media: [FeedNote] = []
    var replies: [FeedNote] = []
    var reposts: [FeedNote] = []
    var tagged: [FeedNote] = []
}

/// Full screen on iPhone and iPad, a sized sheet on the Mac.
struct FollowListHost<Page: View>: ViewModifier {
    @Binding var item: FollowListTab?
    let page: (FollowListTab) -> Page

    func body(content: Content) -> some View {
        #if os(iOS)
        content.fullScreenCover(item: $item) { page($0) }
        #else
        content.sheet(item: $item) { page($0).frame(minWidth: 520, minHeight: 640) }
        #endif
    }
}
