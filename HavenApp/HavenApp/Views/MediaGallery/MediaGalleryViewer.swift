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
    /// False for the pages the pager builds either side of the one showing.
    var isOnScreen: Bool = true
    /// Picture in Picture took the clip over: the viewer closes.
    var onPiPStart: (() -> Void)? = nil
    @State private var resolvedType: MediaItem.MediaType
    @State private var isLoadingType = false

    init(mediaItem: MediaItem, isOnScreen: Bool = true, onPiPStart: (() -> Void)? = nil) {
        self.mediaItem = mediaItem
        self.isOnScreen = isOnScreen
        self.onPiPStart = onPiPStart
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
                #if os(iOS)
                // The same player the feed's viewer uses: same controls, PiP,
                // and the clip keeps playing where the feed left it. Only the
                // page on screen gets one, so the pages either side stay quiet.
                if isOnScreen {
                    FullScreenVideoPlayer(url: mediaItem.url, mimeType: mediaItem.mimeType, onPiPStart: onPiPStart)
                } else {
                    Color.black
                }
                #else
                VideoPlayerView(url: mediaItem.url, mimeType: mediaItem.mimeType)
                #endif
            } else if resolvedType == .audio {
                AudioPlayerView(url: mediaItem.url)
            } else if resolvedType == .unknown {
                VStack(spacing: 12) {
                    Image(systemName: "doc.fill")
                        .font(.appSystem(size: 64))
                        .foregroundColor(Color.accentText.opacity(0.6))
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
        // Photos, GIFs and videos alike fall back to the author's vault on the mesh.
        .meshMediaNote(for: mediaItem)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            detectType()
        }
        #if os(iOS)
        // Only the full-screen gallery and profile viewers show this.
        // Photos stay upright; only the clip on screen may turn the phone.
        .landscapeSlot(held: LandscapeCount.pageHolds(isClip: isClip, isOnScreen: isOnScreen, isClosing: false))
        #endif
    }

    private var isClip: Bool { resolvedType == .video || isVideoByMime }

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
    /// media display (via `MediaItemRenderer`), the shared `ViewerActionBar`
    /// (copy, save, share, ··· link and delete), mirror status, drag down to dismiss, drag up
    /// (or the grabber, or ↑ on the Mac) for the notes that use the file,
    /// and left/right navigation via `TabView`.
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
                        ViewerActionBar(
                            url: item.url,
                            isClip: item.type == .video,
                            link: configService.hasExternalShareURL(for: item.url)
                                ? item.shareURL(with: configService).absoluteString : nil,
                            onDelete: { pendingViewerDelete = $0 }
                        )

                        SourceIndicatorView(
                            url: item.url,
                            onMirrorComplete: {
                                loadLocalMedia(force: true)
                            }
                        )

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
                    MediaItemRenderer(mediaItem: mediaItem, isOnScreen: mediaItem == selectedMedia, onPiPStart: {
                        selectedMedia = nil
                        dragOffset = .zero
                    })
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
                            // Down closes; up lists the notes that use the file.
                            if dragOffset.height > 120 {
                                withAnimation(Motion.dismiss) {
                                    selectedMedia = nil
                                    dragOffset = .zero
                                }
                            } else if dragOffset.height < -120 {
                                withAnimation(Motion.snapBack) { dragOffset = .zero }
                                showingMediaNotes = true
                            } else {
                                withAnimation(Motion.snapBack) {
                                    dragOffset = .zero
                                }
                            }
                        }
                )

                Spacer()

                MediaViewerNoteGrabber(title: "Notes") { showingMediaNotes = true }
                    .opacity(max(0, 1.0 - (abs(dragOffset.height) / 100.0)))

                Text(configService.externalShareURL(for: item.url).absoluteString)
                    .font(.appCaption.monospaced())
                    .foregroundColor(.secondary)
                    .padding(.bottom)
                    .opacity(max(0, 1.0 - (abs(dragOffset.height) / 100.0)))
            }
        }
        .sheet(isPresented: $showingMediaNotes) {
            MediaNotesSheet(notes: notesUsing(item)) { openNoteFromViewer($0) }
                .environmentObject(nostrService)
        }
        .confirmMediaDelete($pendingViewerDelete, hash: extractViewerSHA256(from: item.url)) { scope in
            switch scope {
            case .mirrors: deleteMediaFromMirrors(item: item)
            case .everywhere: deleteMediaEverywhere(item: item)
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

    // MARK: Shared viewer (iPhone/iPad)

    /// Opens the feed's viewer on `item`, paging across the Media page as it
    /// is sorted and filtered, with what only this page has: the vault
    /// badge, the notes that use the file, and its own delete.
    func makeViewerItem(for item: MediaItem) -> IdentifiableURL {
        let byURL = Dictionary(displayMedia.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<URL>()
        let urls = displayMedia.map(\.url).filter { seen.insert($0).inserted }
        let extras = MediaViewerExtras(
            mimeHint: { byURL[$0]?.mimeType },
            meshNote: { url in
                byURL[url].flatMap { item in item.pubkey.map { MeshMediaNote(author: $0, tags: item.tags ?? []) } }
            },
            customPage: { url in
                guard let item = byURL[url], item.type == .audio || item.type == .unknown else { return nil }
                return AnyView(MediaItemRenderer(mediaItem: item))
            },
            badge: { url in
                AnyView(SourceIndicatorView(url: url, onMirrorComplete: { loadLocalMedia(force: true) }))
            },
            onDelete: { url, scope in
                guard let item = byURL[url] else { return }
                switch scope {
                case .mirrors: deleteMediaFromMirrors(item: item)
                case .everywhere: deleteMediaEverywhere(item: item)
                }
            },
            notes: { url in byURL[url].map { notesUsing($0) } ?? [] },
            onOpenNote: { openNoteFromViewer($0) },
            onPage: { url in
                if let item = byURL[url] { selectedMedia = item }
            }
        )
        return IdentifiableURL(url: item.url, allURLs: urls, extras: extras)
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

    /// Every note on the vault that uses the file, by URL or sha256, in the
    /// text or a tag, any author, newest first (`MediaNoteMatch`). Only what
    /// the vault already holds: no network lookup.
    func notesUsing(_ item: MediaItem) -> [NostrEvent] {
        let byId = Dictionary(nostrService.events.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let found = MediaNoteMatch.notes(using: item.url, in: nostrService.events.map {
            MediaNoteMatch.Note(id: $0.id, kind: $0.kind, createdAt: $0.created_at, content: $0.content, tags: $0.tags)
        })
        return found.compactMap { byId[$0.id] }
    }

    /// A row in the notes sheet: the sheet and the viewer close, then the note opens.
    func openNoteFromViewer(_ id: String) {
        showingMediaNotes = false
        withAnimation(Motion.fade) {
            selectedMedia = nil
            dragOffset = .zero
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            showingNoteId = id
        }
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
            case 126: // up arrow -- the notes that use the file (the Mac's swipe up)
                showingMediaNotes = true
                return nil
            case 125, 53: // down arrow, escape -- close
                guard !showingMediaNotes else { return event }
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
