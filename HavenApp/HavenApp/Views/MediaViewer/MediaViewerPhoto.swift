import SwiftUI

// MARK: - MediaViewerPhoto

/// Cached photo view for the full-screen media viewer.
/// Uses MediaCacheService instead of AsyncImage to avoid re-downloads.
struct MediaViewerPhoto: View {
    let url: URL
    /// Starts with the copy the feed already decoded, so the zoom grows out
    /// of the photo rather than an empty frame; the full-size one replaces it
    /// once loaded.
    @State private var image: PlatformImage?
    @State private var loadFailed = false
    @State private var loadedFull = false
    @State private var phase: MeshMediaPhase = .loading
    /// The gallery passes its item's note down; the feed's viewer is opened
    /// outside the note, which leaves it at the tap.
    @Environment(\.meshMediaNote) private var envNote
    @State private var tappedNote = MeshMediaTap.note

    init(url: URL) {
        self.url = url
        // A neighbour the pager preloaded opens at full size, no spinner and
        // no swap from the feed's smaller copy.
        if let preloaded = ViewerPhotoPreloader.image(for: url) {
            _image = State(initialValue: preloaded)
            _loadedFull = State(initialValue: true)
        } else {
            _image = State(initialValue: MediaCacheService.shared.cachedImage(for: url))
        }
    }

    private var meshNote: MeshMediaNote? { envNote ?? tappedNote }

    var body: some View {
        ZStack {
            if let image = image {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFit()
            } else if phase == .meshLookup {
                MeshMediaStatusView(phase: phase, onDark: true)
            } else if loadFailed {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.appSystem(size: 40))
                        .foregroundColor(.orange)
                    Text(phase.text() ?? "Failed to load image")
                        .foregroundColor(.white)
                        .font(.appHeadline)
                    Text(url.absoluteString)
                        .foregroundColor(.secondary)
                        .font(.appCaption)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            } else {
                ProgressView().tint(.white)
            }
        }
        .onAppear { loadImage() }
    }

    private func loadImage() {
        guard !loadedFull, !loadFailed else { return }
        let imetaSha256 = meshNote?.imetaSha256[url.absoluteString]
        // A photo read by its note's imeta hash is cached under that hash.
        if image == nil, let sha = imetaSha256 {
            image = MediaCacheService.shared.cachedImage(for: MeshMediaRouter.blobCacheKey(sha256: sha))
        }
        Task {
            guard let (data, _) = await MediaCacheService.shared.fetchData(
                url: url, meshAuthor: meshNote?.author, imetaSha256: imetaSha256,
                onLookup: { if image == nil { phase = .meshLookup } }
            ) else {
                // Keep the feed's copy on screen if there is one.
                await MainActor.run {
                    phase = .failed(after: phase, meshOnly: MediaCacheService.isMeshOnly(url))
                    if self.image == nil { self.loadFailed = true }
                }
                return
            }
            // Screen-bounded decode: the pager keeps neighbor pages alive, so
            // full-resolution originals (50-190 MB decoded) stack up fast.
            let downsampled = await ImageDownsampler.downsampleToScreen(data: data)
            if let img = downsampled ?? PlatformImage(data: data) {
                ViewerPhotoPreloader.store(img, for: url)
                await MainActor.run { self.image = img; self.loadedFull = true }
            } else {
                await MainActor.run { if self.image == nil { self.loadFailed = true } }
            }
        }
    }
}

// MARK: - ViewerPhotoPreloader

/// Screen-size decodes of the photos either side of the one showing, so a swipe
/// in the full-screen pager lands on the photo instead of a spinner. Small and
/// count-bounded: a screen-size decode is ~15 MB, and the pager only ever needs
/// the current page and its two neighbours.
enum ViewerPhotoPreloader {
    private static let cache: NSCache<NSURL, PlatformImage> = {
        let c = NSCache<NSURL, PlatformImage>()
        c.countLimit = 4
        return c
    }()
    @MainActor private static var inFlight = Set<URL>()

    static func image(for url: URL) -> PlatformImage? { cache.object(forKey: url as NSURL) }

    static func store(_ image: PlatformImage, for url: URL) { cache.setObject(image, forKey: url as NSURL) }

    /// Fetches and decodes `url` at screen size unless it is already decoded or
    /// on its way. Videos and GIFs are left to their own players; a type that
    /// is not known yet costs the same HEAD the page itself would make.
    @MainActor
    static func preload(_ url: URL, note: MeshMediaNote?) {
        guard image(for: url) == nil, !inFlight.contains(url) else { return }
        inFlight.insert(url)
        let imetaSha256 = note?.imetaSha256[url.absoluteString]
        Task(priority: .userInitiated) {
            defer { inFlight.remove(url) }
            // Only a known photo: an unclassified URL could be a whole video.
            guard await MediaKindResolver.kind(for: url) == .image,
                  let (data, _) = await MediaCacheService.shared.fetchData(
                url: url, meshAuthor: note?.author, imetaSha256: imetaSha256
            ), !AnimatedImageHelper.isGIFData(data),
                  let img = await ImageDownsampler.downsampleToScreen(data: data) else { return }
            store(img, for: url)
        }
    }
}

extension View {
    @ViewBuilder
    func simultaneousGestureIf<T: Gesture>(_ enabled: Bool, _ gesture: T) -> some View {
        if enabled {
            self.simultaneousGesture(gesture)
        } else {
            self
        }
    }
}
