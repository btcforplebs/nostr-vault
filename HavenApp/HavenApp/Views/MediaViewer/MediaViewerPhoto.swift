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
        _image = State(initialValue: MediaCacheService.shared.cachedImage(for: url))
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
                await MainActor.run { self.image = img; self.loadedFull = true }
            } else {
                await MainActor.run { if self.image == nil { self.loadFailed = true } }
            }
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
