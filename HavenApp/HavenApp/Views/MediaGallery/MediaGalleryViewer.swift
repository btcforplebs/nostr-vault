import SwiftUI
#if os(macOS)
import AppKit
#endif

// MARK: - MediaItemRenderer

/// Displays a single media item in the full-screen viewer, resolving its type
/// (image, video, audio, animated GIF, or unknown) and presenting the
/// appropriate player/view.
struct MediaItemRenderer: View {
    let mediaItem: MediaItem
    @State private var resolvedType: MediaItem.MediaType
    @State private var isLoadingType = false

    init(mediaItem: MediaItem) {
        self.mediaItem = mediaItem
        self._resolvedType = State(initialValue: mediaItem.type)
    }

    private var isVideoByMime: Bool {
        mediaItem.mimeType?.lowercased().hasPrefix("video/") == true
    }

    var body: some View {
        Group {
            if isLoadingType {
                ProgressView()
                    .tint(.white)
            } else if resolvedType == .video || isVideoByMime {
                VideoPlayerView(url: mediaItem.url, mimeType: mediaItem.mimeType)
            } else if resolvedType == .audio {
                AudioPlayerView(url: mediaItem.url)
            } else if resolvedType == .unknown {
                VStack(spacing: 12) {
                    Image(systemName: "doc.fill")
                        .font(.appSystem(size: 64))
                        .foregroundColor(Color.havenPurple.opacity(0.6))
                    if let mime = mediaItem.mimeType {
                        Text(mime)
                            .font(.appSystem(size: 14, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)
                    } else {
                        Text("Unknown Format")
                            .font(.appHeadline)
                            .foregroundColor(.secondary)
                    }
                }
            } else if mediaItem.isAnimatedGIF {
                AnimatedImage(url: mediaItem.url, contentMode: .fit, shouldAnimate: true)
            } else {
                RetryableAsyncImage(url: mediaItem.url, contentMode: .fit)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            detectType()
        }
    }

    private func detectType() {
        if resolvedType != .unknown {
            return
        }

        if let kind = MediaKindResolver.cachedKind(for: mediaItem.url, mimeHint: mediaItem.mimeType) {
            resolvedType = Self.mediaType(from: kind)
            return
        }
        isLoadingType = true
        Task { @MainActor in
            let kind = await MediaKindResolver.kind(for: mediaItem.url, mimeHint: mediaItem.mimeType)
            resolvedType = Self.mediaType(from: kind)
            isLoadingType = false
        }
    }

    private static func mediaType(from kind: MediaKind) -> MediaItem.MediaType {
        switch kind {
        case .video: return .video
        case .image, .gif: return .image
        case .audio: return .audio
        case .unknown: return .unknown
        }
    }
}

/// Backward-compatible alias so ProfileView (and any other file still
/// referencing the original name) continues to compile.
typealias ViewerViewMediaItem = MediaItemRenderer

// MARK: - MediaGalleryView Full-Screen Viewer

extension MediaGalleryView {

    /// The full-screen media viewer content for a given item. Contains the
    /// media display (via `MediaItemRenderer`), toolbar buttons (copy link,
    /// save to photos, delete, mirror status, view note), drag-to-dismiss
    /// gesture, and left/right navigation via `TabView`.
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
                                withAnimation(Motion.snapBack) {
                                    isCopied = true
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                                    withAnimation(Motion.fade) {
                                        isCopied = false
                                    }
                                }
                            }) {
                                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                                    .font(.appSystem(size: 16, weight: .semibold))
                                    .foregroundColor(isCopied ? .green : .white)
                                    .padding(10)
                                    .background(Color.white.opacity(0.1))
                                    .cornerRadius(8)
                                    .scaleEffect(isCopied ? 1.15 : 1.0)
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

                        Menu {
                            Button(role: .destructive, action: {
                                deleteMediaFromMirrors(item: item)
                            }) {
                                Label("Delete from mirrors", systemImage: "trash")
                            }
                            Button(role: .destructive, action: {
                                deleteMediaEverywhere(item: item)
                            }) {
                                Label("Delete everywhere", systemImage: "trash.fill")
                            }
                        } label: {
                            Image(systemName: "trash")
                                .font(.appSystem(size: 16, weight: .semibold))
                                .padding(10)
                                .background(Color.white.opacity(0.1))
                                .cornerRadius(8)
                        }
                        .buttonStyle(.plain)

                        SourceIndicatorView(
                            url: item.url,
                            onMirrorComplete: {
                                loadLocalMedia(force: true)
                            }
                        )

                        if let noteId = findNoteId(for: item) {
                            Button(action: {
                                withAnimation(Motion.fade) {
                                    selectedMedia = nil
                                    dragOffset = .zero
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    showingNoteId = noteId
                                }
                            }) {
                                Image(systemName: "doc.text")
                                    .font(.appSystem(size: 16, weight: .semibold))
                                    .foregroundColor(.white)
                                    .padding(10)
                                    .background(Color.white.opacity(0.1))
                                    .cornerRadius(8)
                            }
                            .buttonStyle(.plain)
                        }

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
                    #if os(iOS)
                    if let message = saveToPhotosMessage {
                        Text(message)
                            .font(.appCaption)
                            .foregroundColor(message.contains("Saved") ? .green : .red)
                            .transition(.opacity)
                    }
                    #endif
                    if isCopied {
                        Text("Link copied to clipboard")
                            .font(.appCaption)
                            .foregroundColor(.green)
                            .transition(.opacity)
                    }
                }
                .padding()
                .opacity(max(0, 1.0 - (abs(dragOffset.height) / 100.0)))

                Spacer()

                MediaPagerView(items: displayMedia, selection: $selectedMedia, enableKeyboardNavigation: true) { mediaItem in
                    MediaItemRenderer(mediaItem: mediaItem)
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
                            // Only capture vertical drags to not conflict with horizontal swiping
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

                Text(configService.externalShareURL(for: item.url).absoluteString)
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
        #if os(macOS)
        .onAppear { installKeyMonitor() }
        .onDisappear { removeKeyMonitor() }
        #endif
    }

    // MARK: Full-Screen Overlay

    /// macOS path: traditional in-window overlay.
    @ViewBuilder
    var fullScreenOverlay: some View {
        if let item = selectedMedia {
            mediaViewerContent(for: item)
        }
    }

    /// Binding wrapping `selectedMedia` for `.fullScreenCover(isPresented:)`.
    /// Resets the drag offset when dismissed so the next presentation is not shifted.
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

    // MARK: Note Lookup

    /// Find the Nostr event ID for a media item by matching its URL or blossom
    /// hash against stored events.
    func findNoteId(for item: MediaItem) -> String? {
        let mediaURL = item.url.absoluteString
        // Try exact URL match first
        if let event = nostrService.events.first(where: { $0.content.contains(mediaURL) }) {
            return event.id
        }
        // For blossom URLs the displayed URL may differ from the original;
        // fall back to matching the SHA256 hash embedded in the URL path.
        let hash = item.url.lastPathComponent
        if hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) {
            return nostrService.events.first(where: { $0.content.contains(hash) })?.id
        }
        return nil
    }

    // MARK: Navigation

    /// Moves `selectedMedia` to the previous (direction == -1) or next
    /// (direction == 1) item in `displayMedia`.
    func navigateMedia(direction: Int) {
        guard let current = selectedMedia,
              let index = displayMedia.firstIndex(where: { $0.id == current.id }) else { return }
        let newIndex = index + direction
        guard displayMedia.indices.contains(newIndex) else { return }
        withAnimation(Motion.fade) { selectedMedia = displayMedia[newIndex] }
    }

    // MARK: macOS Key Monitor

    #if os(macOS)
    /// Installs a local NSEvent monitor for keyboard navigation (left/right
    /// arrows to navigate media, Escape to dismiss).
    func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard selectedMedia != nil else { return event }
            switch event.keyCode {
            case 123: // left arrow -- previous item in grid
                navigateMedia(direction: -1)
                return nil
            case 124: // right arrow -- next item in grid
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

    /// Removes the previously installed key monitor, if any.
    func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }
    #endif
}
