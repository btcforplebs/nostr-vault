import SwiftUI
import Combine
import ImageIO
#if os(iOS)
import Photos
#endif

extension ProfileContent {
    // MARK: - Media

    /// The media tab's tiles, one per file. Built once per set of posts (see
    /// `ProfileMediaItems`), not on every redraw of the page.
    private var displayMedia: [MediaItem] {
        ProfileMediaItems.shared.items(for: loader.buckets.media).items
    }

    var isPresentingViewer: Binding<Bool> {
        Binding(
            get: { selectedMedia != nil },
            set: { presenting in
                if !presenting {
                    selectedMedia = nil
                    dragOffset = .zero
                }
            }
        )
    }

    func mediaGrid(notes: [FeedNote]) -> some View {
        #if os(macOS)
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)
        let gridSpacing: CGFloat = 8
        #else
        // Three across on a phone; a wider pane (iPad, either orientation)
        // gets more tiles rather than three stretched ones. 16 is the grid's
        // own horizontal padding, below.
        let gridSpacing: CGFloat = 6
        let columns = AdaptiveLayout.columns(width: viewportWidth - 16, ideal: 180,
                                             spacing: gridSpacing, minimum: 3, maximum: 6)
        #endif

        let built = ProfileMediaItems.shared.items(for: loader.buckets.media)
        let items = built.items

        return VStack(spacing: 0) {
            LazyVGrid(columns: columns, spacing: gridSpacing) {
                ForEach(items) { mediaItem in
                    // Your own files get the Vault grid's Delete menu; only a
                    // Blossom file (named by its hash) can be deleted.
                    let hash = canDeleteMedia ? built.blossomHashes[mediaItem.id] : nil
                    MediaGridItem(
                        item: mediaItem,
                        onDeleteFromMirrors: hash.map { hash in { _ in deleteFromMirrors(hash: hash) } },
                        onDeleteEverywhere: hash.map { hash in { _ in deleteEverywhere(hash: hash) } }
                    ) {
                        withAnimation(Motion.fade) {
                            selectedMedia = mediaItem
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 2)

            olderPageSentinel(itemCount: items.count)
        }
    }

    private func deleteFromMirrors(hash: String) {
        Task {
            await MediaBackupActions.deleteFromMirrors(hash: hash, configService: configService, nostrService: nostrService)
        }
    }

    /// The tile stays: it belongs to a post, and the post is still up unless
    /// "Delete file and post" was chosen (see `.havenOwnEventsDeleted`).
    private func deleteEverywhere(hash: String) {
        Task {
            await MediaBackupActions.deleteEverywhere(hash: hash, configService: configService, nostrService: nostrService)
        }
    }

    @ViewBuilder
    func mediaViewerContent(for item: MediaItem) -> some View {
        ZStack {
            Color.black.opacity(0.9 * max(0, 1.0 - (abs(dragOffset.height) / 300.0)))
                .edgesIgnoringSafeArea(.all)
                .onTapGesture {
                    withAnimation(Motion.fade) {
                        selectedMedia = nil
                        dragOffset = .zero
                    }
                }

            VStack {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        if configService.hasExternalShareURL(for: item.url) {
                            Button(action: {
                                PlatformClipboard.copy(item.shareURL(with: configService).absoluteString)
                            }) {
                                Image(systemName: "doc.on.doc")
                                    .font(.appSystem(size: 16, weight: .semibold))
                                    .padding(10)
                                    .background(Color.white.opacity(0.1))
                                    .cornerRadius(8)
                            }
                            .buttonStyle(.plain)
                        }

                        #if os(iOS)
                        if item.type == .image || item.type == .video {
                            Button(action: {
                                saveMediaToPhotos(item: item)
                            }) {
                                Image(systemName: "square.and.arrow.down")
                                    .font(.appSystem(size: 16, weight: .semibold))
                                    .padding(10)
                                    .background(Color.white.opacity(0.1))
                                    .cornerRadius(8)
                            }
                            .buttonStyle(.plain)
                        }
                        #endif

                        SourceIndicatorView(url: item.url)

                        Spacer()

                        Button(action: {
                            withAnimation(Motion.fade) {
                                selectedMedia = nil
                                dragOffset = .zero
                            }
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.appTitle)
                                .foregroundColor(.white.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
                #if os(iOS)
                .keepsPillLaneBelow()
                #endif
                .opacity(max(0, 1.0 - (abs(dragOffset.height) / 100.0)))

                Spacer()

                MediaPagerView(items: displayMedia, selection: $selectedMedia, enableKeyboardNavigation: true, showsPositionBar: false) { mediaItem in
                    ViewerViewMediaItem(mediaItem: mediaItem)
                        #if os(iOS)
                        .transition(.opacity.animation(Motion.media))
                        #endif
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .offset(y: dragOffset.height)
                .scaleEffect(max(0.8, 1.0 - (abs(dragOffset.height) / 1000.0)))
                .gesture(
                    DragGesture()
                        .onChanged { gesture in
                            if abs(gesture.translation.height) > abs(gesture.translation.width) || dragOffset.height != 0 {
                                dragOffset = CGSize(width: 0, height: gesture.translation.height)
                            }
                        }
                        .onEnded { gesture in
                            if abs(dragOffset.height) > 120 {
                                withAnimation(Motion.dismiss) {
                                    selectedMedia = nil
                                    dragOffset = .zero
                                }
                            } else {
                                withAnimation(Motion.snapBack) {
                                    dragOffset = .zero
                                }
                            }
                        }
                )

                Spacer()

                Text(item.shareURL(with: configService).absoluteString)
                    .font(.appCaption.monospaced())
                    .foregroundColor(.secondary)
                    .padding(.bottom)
                    .opacity(max(0, 1.0 - (abs(dragOffset.height) / 100.0)))
            }
        }
        .transition(.opacity)
        #if os(iOS)
        .background(ClearFullScreenBackground())
        #endif
    }

    @ViewBuilder
    var fullScreenOverlay: some View {
        #if os(macOS)
        if let item = selectedMedia {
            mediaViewerContent(for: item)
        }
        #endif
    }

    #if os(iOS)
    private func saveMediaToPhotos(item: MediaItem) {
        Task {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                await MainActor.run {
                    ErrorNotificationManager.shared.show("Photo library access denied")
                }
                return
            }

            let session = URLSession(configuration: .default, delegate: LocalhostTrustDelegate(), delegateQueue: nil)
            do {
                let (data, _) = try await session.data(from: item.url)

                if item.type == .video {
                    let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
                    try data.write(to: tempURL)
                    try await PHPhotoLibrary.shared().performChanges {
                        PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: tempURL, options: nil)
                    }
                    try? FileManager.default.removeItem(at: tempURL)
                } else {
                    try await PHPhotoLibrary.shared().performChanges {
                        let request = PHAssetCreationRequest.forAsset()
                        let options = PHAssetResourceCreationOptions()
                        request.addResource(with: .photo, data: data, options: options)
                    }
                }

                await MainActor.run {
                    ActionToastManager.shared.show(icon: "photo.on.rectangle", message: "Saved to Photos", tone: .success)
                }
            } catch {
                await MainActor.run {
                    ErrorNotificationManager.shared.show("Failed to save")
                }
            }
        }
    }
    #endif

    #if os(macOS)
    func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard selectedMedia != nil else { return event }
            switch event.keyCode {
            case 123: // left arrow
                navigateMedia(direction: -1)
                return nil
            case 124: // right arrow
                navigateMedia(direction: 1)
                return nil
            case 53: // escape
                withAnimation(Motion.fade) { selectedMedia = nil }
                return nil
            default:
                return event
            }
        }
    }

    func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }
    #endif

    private func navigateMedia(direction: Int) {
        let media = displayMedia
        guard let current = selectedMedia,
              let index = media.firstIndex(where: { $0.id == current.id }) else { return }
        let newIndex = index + direction
        guard media.indices.contains(newIndex) else { return }
        withAnimation(Motion.fade) { selectedMedia = media[newIndex] }
    }
}

/// The media tab's tiles, built once per set of posts. Building them hashes
/// every URL into an id and looks up its type, and the page redraws many
/// times a second while it loads, so each redraw used to rebuild them all.
///
/// A file with no extension (a Blossom hash) is guessed to be an image until
/// its type is detected; the set is rebuilt once a guessed URL's type is known.
@MainActor
final class ProfileMediaItems {
    static let shared = ProfileMediaItems()

    struct Built {
        let items: [MediaItem]
        /// The Blossom hash of each tile's file, for its Delete menu.
        let blossomHashes: [UUID: String]
        /// URLs whose type was guessed from the extension alone.
        let guessed: [URL]
    }

    private var noteIDs: [String] = []
    private var built = Built(items: [], blossomHashes: [:], guessed: [])

    func items(for notes: [FeedNote]) -> Built {
        let ids = notes.map(\.id)
        let typeArrived = built.guessed.contains { MediaTypeDetector.shared.getCachedContentType(for: $0) != nil }
        if ids != noteIDs || typeArrived {
            noteIDs = ids
            built = Self.build(notes)
        }
        return built
    }

    private static func build(_ notes: [FeedNote]) -> Built {
        var items: [MediaItem] = []
        var hashes: [UUID: String] = [:]
        var guessed: [URL] = []
        for note in notes {
            for url in note.mediaURLs {
                let ext = url.pathExtension.lowercased()
                var isGIF = ext == "gif"
                var isVideo = SupportedMediaFormats.videoExtensions.contains(ext)
                var isAudio = SupportedMediaFormats.audioExtensions.contains(ext)

                if let cachedMime = MediaTypeDetector.shared.getCachedContentType(for: url) {
                    isGIF = MediaTypeDetector.shared.isGIFContentType(cachedMime)
                    isVideo = MediaTypeDetector.shared.isVideoContentType(cachedMime)
                    isAudio = cachedMime.lowercased().hasPrefix("audio/")
                } else {
                    guessed.append(url)
                }

                let type: MediaItem.MediaType = isVideo ? .video : (isAudio ? .audio : .image)
                let mime = isGIF ? "image/gif" : (isVideo ? "video/mp4" : nil)
                let item = MediaItem(
                    id: UUID.deterministic(from: url.absoluteString),
                    url: url,
                    type: type,
                    dateAdded: note.createdAt,
                    pubkey: note.pubkey,
                    tags: note.tags,
                    mimeType: mime
                )
                items.append(item)
                if let hash = MediaCacheService.blossomHash(in: url) { hashes[item.id] = hash }
            }
        }
        return Built(items: items, blossomHashes: hashes, guessed: guessed)
    }
}
