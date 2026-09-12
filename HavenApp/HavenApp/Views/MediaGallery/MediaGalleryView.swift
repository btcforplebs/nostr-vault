import SwiftUI
import AVFoundation
import Combine
import PhotosUI
import UniformTypeIdentifiers
#if os(iOS)
import Photos
#endif

struct MediaGalleryView: View {

    nonisolated static let hexPattern = try! NSRegularExpression(pattern: "[a-f0-9]{64}", options: .caseInsensitive)

    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var relayManager: RelayProcessManager
    @StateObject var feedService = FeedService.shared
    @ObservedObject var blossomCache = BlossomMediaCache.shared

    // MARK: - State

    @State var navigationPath = NavigationPath()
    @State var selectedMedia: MediaItem? = nil
    @State var initialLoad = false
    @State var mediaSourceFilter: MediaSourceFilter = .all
    @State var mediaLocationFilter: MediaLocationFilter = .all
    @State var contentFilter: ContentFilter = .all

    // Type filter, layout and sort survive leaving the tab and relaunching.
    // Stored as raw strings because AppStorage cannot hold a Set or a bare enum.
    @AppStorage("mediaGallery.typeFilter") var mediaTypeFilterRaw: String =
        MediaTypeFilter.allCases.map(\.rawValue).joined(separator: ",")
    @AppStorage("mediaGallery.layoutMode") var mediaLayoutModeRaw: String = MediaLayoutMode.grid.rawValue
    @AppStorage("mediaGallery.sortOption") var sortOptionRaw: String = MediaSortOption.newestFirst.rawValue

    /// Selected media types. Reading rebuilds the set from storage; writing
    /// normalises to `allCases` order so the stored string is stable.
    var mediaTypeFilter: Set<MediaTypeFilter> {
        get {
            let stored = Set(mediaTypeFilterRaw
                .split(separator: ",")
                .compactMap { MediaTypeFilter(rawValue: String($0)) })
            // An empty selection shows nothing at all and there is no UI path
            // back from it, so treat "none stored" as "everything".
            return stored.isEmpty ? Set(MediaTypeFilter.allCases) : stored
        }
        nonmutating set {
            mediaTypeFilterRaw = MediaTypeFilter.allCases
                .filter { newValue.contains($0) }
                .map(\.rawValue)
                .joined(separator: ",")
        }
    }

    var mediaLayoutMode: MediaLayoutMode {
        get { MediaLayoutMode(rawValue: mediaLayoutModeRaw) ?? .grid }
        nonmutating set { mediaLayoutModeRaw = newValue.rawValue }
    }

    var sortOption: MediaSortOption {
        get { MediaSortOption(rawValue: sortOptionRaw) ?? .newestFirst }
        nonmutating set { sortOptionRaw = newValue.rawValue }
    }

    // Cached display data (computed in background)
    @State var displayMedia: [MediaItem] = []

    // Stable loading state so the empty-state message doesn't flash
    // before the display data has been computed at least once.
    @State var mediaHasLoadedOnce: Bool = false

    #if os(macOS)
    @State var keyMonitor: Any? = nil
    #endif

    @State var dragOffset: CGSize = .zero

    // Blossom dashboard
    @State var showingBlossomMediaList = false

    // Media Uploads
    @State var selectedUploadItems: [PhotosPickerItem] = []
    @State var showingFileImporter = false
    @State var showingPhotoPicker = false
    @State var showingUploadOptions = false
    @State var photosPickerFilter: PHPickerFilter = .any(of: [.images, .videos])
    @State var isPastingContent = false
    @State var activeUploadTasks: [Task<Void, Never>] = []

    #if os(iOS)
    @State var saveToPhotosMessage: String?
    #endif
    @State var isCopied = false

    @State var maxDisplayedItems: Int = 50

    // Debounce mechanism for updateDisplayData
    @State var updateTask: Task<Void, Never>?
    @State var updateGeneration: Int = 0

    // Debounce refreshAll() to prevent rapid-fire resubscriptions
    @State var refreshDebounceTask: Task<Void, Never>?

    // Profile / Note sheets opened from the media viewer
    @State var showingProfilePubkey: String?
    @State var showingNoteId: String?

    // MARK: - Computed Properties

    var blossomService: BlossomService {
        BlossomService(configService: configService, nostrService: nostrService)
    }

    var statusColor: Color {
        switch nostrService.connectionColor {
        case "green": return .green
        case "yellow": return .yellow
        case "red": return .red
        default: return .gray
        }
    }


    // MARK: - Body

    var body: some View {
        #if os(iOS)
        NavigationStack(path: $navigationPath) {
            iOSContent
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.hidden, for: .navigationBar)
        }
        #else
        viewContent
        #endif
    }

    // MARK: - iOS Root Content
    /// Flat content view with toolbar + handlers, navigation modifiers applied in body.
    var iOSContent: some View {
        viewContentPlatform
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                leadingToolbarInline
            }
            #if os(iOS)
            ToolbarItem(placement: .navigationBarTrailing) {
                ViewThatFits {
                    trailingToolbarInline
                    trailingToolbarMenu
                }
            }
            #else
            ToolbarItem(placement: .automatic) {
                trailingToolbarInline
            }
            #endif
        }
        .onAppear {
            if relayManager.isRunning && !relayManager.isBooting {
                let recentlyReconnected: Bool
                if let lastReconnect = nostrService.lastForegroundReconnectTime {
                    recentlyReconnected = Date().timeIntervalSince(lastReconnect) < 3.0
                } else {
                    recentlyReconnected = false
                }
                if nostrService.connectionStatus == "Disconnected" && !recentlyReconnected {
                    refreshAll()
                }
                initialLoad = true
                updateDisplayData()
            }
            loadLocalMedia()
            triggerAutoMirrorIfEnabled()
        }
        .onChange(of: relayManager.isBooting) { _, isBooting in
            if !isBooting && relayManager.isRunning {
                refreshAll()
                initialLoad = true
                triggerAutoMirrorIfEnabled()
            }
        }
        .onChange(of: relayManager.isRunning) { _, isRunning in
            if isRunning && !relayManager.isBooting {
                refreshAll()
                initialLoad = true
            }
        }
        .modifier(mediaChangeHandlers)
        .modifier(MagicPasteFromWidget { handlePasteFromClipboard() })
        .modifier(mediaSheetsAndPickers)
    }

    // MARK: - Platform Content

    @ViewBuilder
    var viewContentPlatform: some View {
        #if os(iOS)
        // Full-bleed layout: ScrollView in a ZStack so content scrolls
        // behind the transparent navigation bar, enabling the glass toolbar effect.
        ZStack {
            Color.platformWindowBackground.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    listContent

                    if !displayMedia.isEmpty {
                        Color.clear
                            .frame(height: 1)
                            .padding(.bottom, 20)
                            .onAppear {
                                loadMoreItems()
                            }
                    }
                }
                .tabBarBottomPadding()
            }
            .scrollDismissesKeyboard(.interactively)
            .refreshable {
                refreshAll()
            }
            .scrollDirectionTracking(feedService: feedService)
        }
        .overlay(alignment: .bottomTrailing) {
            if !feedService.feedScrollingDown {
                Button(action: { showingBlossomMediaList = true }) {
                    HStack(spacing: 6) {
                        Image(systemName: "camera.macro")
                            .font(.appSystem(size: 15, weight: .bold))
                        Text("Blossom")
                            .font(.appSystem(size: 14, weight: .bold, design: .rounded))
                    }
                    .foregroundColor(.white)
                    .frame(height: 48)
                    .padding(.horizontal, 18)
                    .background(
                        Capsule()
                            .fill(Color.havenPurple)
                            .shadow(color: Color.havenPurple.opacity(0.35), radius: 8, x: 0, y: 4)
                    )
                }
                .padding(.trailing, 20)
                .padding(.bottom, 90)
                .hoverEffect(.lift)
                .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .animation(Motion.chrome, value: feedService.feedScrollingDown)
        #else
        GeometryReader { geometry in
            ZStack {
                Color.platformWindowBackground.ignoresSafeArea()
                compactViewContent(isNarrow: geometry.size.width < 500)
            }
        }
        #endif
    }

    // MARK: - List Content

    @ViewBuilder
    var listContent: some View {
        VStack(spacing: 0) {
            mediaContent
                .animation(.none, value: mediaSourceFilter)
        }
        .padding(.vertical, 16)
        .contentShape(Rectangle())
    }

    // MARK: - macOS View Content

    /// Used on macOS: wraps viewContentPlatform with all onChange/onAppear/onReceive handlers.
    var viewContent: some View {
        viewContentPlatform
        .onAppear {
            if relayManager.isRunning && !relayManager.isBooting {
                let recentlyReconnected: Bool
                if let lastReconnect = nostrService.lastForegroundReconnectTime {
                    recentlyReconnected = Date().timeIntervalSince(lastReconnect) < 3.0
                } else {
                    recentlyReconnected = false
                }
                if nostrService.connectionStatus == "Disconnected" && !recentlyReconnected {
                    refreshAll()
                }
                initialLoad = true
                updateDisplayData()
            }
            loadLocalMedia()
            triggerAutoMirrorIfEnabled()
        }
        .onChange(of: relayManager.isBooting) { _, isBooting in
            if !isBooting && relayManager.isRunning {
                refreshAll()
                initialLoad = true
                triggerAutoMirrorIfEnabled()
            }
        }
        .onChange(of: relayManager.isRunning) { _, isRunning in
            if isRunning && !relayManager.isBooting {
                refreshAll()
                initialLoad = true
            }
        }
        .modifier(mediaChangeHandlers)
        .modifier(MagicPasteFromWidget { handlePasteFromClipboard() })
        .modifier(mediaSheetsAndPickers)
    }

    // MARK: - macOS Compact View

    @ViewBuilder
    func compactViewContent(isNarrow: Bool) -> some View {
        VStack(spacing: 0) {
            desktopHeaderView

            Divider()

            ScrollView {
                VStack(spacing: 0) {
                    listContent

                    if !displayMedia.isEmpty {
                        Color.clear
                            .frame(height: 1)
                            .padding(.bottom, 20)
                            .onAppear {
                                loadMoreItems()
                            }
                    }
                }
                .tabBarBottomPadding()
            }
            .scrollDismissesKeyboard(.interactively)
            .refreshable {
                refreshAll()
            }
            .scrollDirectionTracking(feedService: feedService)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        #if os(iOS)
        .overlay(alignment: .bottomTrailing) {
            if !feedService.feedScrollingDown {
                Button(action: { showingBlossomMediaList = true }) {
                    HStack(spacing: 6) {
                        Image(systemName: "camera.macro")
                            .font(.appSystem(size: 15, weight: .bold))
                        Text("Blossom")
                            .font(.appSystem(size: 14, weight: .bold, design: .rounded))
                    }
                    .foregroundColor(.white)
                    .frame(height: 48)
                    .padding(.horizontal, 18)
                    .background(
                        Capsule()
                            .fill(Color.havenPurple)
                            .shadow(color: Color.havenPurple.opacity(0.35), radius: 8, x: 0, y: 4)
                    )
                }
                .padding(.trailing, 20)
                .padding(.bottom, 90)
                .hoverEffect(.lift)
                .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .animation(Motion.chrome, value: feedService.feedScrollingDown)
        #endif
    }

    // MARK: - macOS Desktop Header

    @ViewBuilder
    var desktopHeaderView: some View {
        VStack(spacing: 12) {
            HStack(spacing: 16) {
                mediaTypeFiltersView

                Spacer()

                // The gallery's only refresh was `.refreshable`, which macOS never
                // surfaces — this is the pointer and ⌘R path to the same call.
                IconFilterButton(
                    icon: "arrow.clockwise",
                    tooltip: "Refresh Media",
                    isSelected: true,
                    color: .havenPurple,
                    action: { refreshAll() }
                )
                .keyboardShortcut("r", modifiers: .command)

                // The Blossom dashboard's only entry points were the iOS-only floating
                // button, so on macOS four screens of storage, mirror and sync state
                // compiled, shipped, and could not be opened.
                IconFilterButton(
                    icon: "camera.macro",
                    tooltip: "Blossom Dashboard",
                    isSelected: true,
                    color: .havenPurple,
                    action: { showingBlossomMediaList = true }
                )
                .keyboardShortcut("b", modifiers: .command)

                sortMenu

                desktopUploadMenu
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal)
        .padding(.vertical, 12)
        .background(Color.platformSecondaryGroupedBackground)
    }

    // MARK: - ViewModifier Helpers

    /// Extracted onChange / onReceive handlers to reduce type-checker complexity.
    var mediaChangeHandlers: MediaGalleryChangeHandlers {
        MediaGalleryChangeHandlers(
            selectedMedia: selectedMedia,
            mediaSourceFilter: mediaSourceFilter,
            mediaLocationFilter: mediaLocationFilter,
            mediaTypeFilter: mediaTypeFilter,
            sortOption: sortOption,
            blossomItemsCount: blossomCache.items.count,
            noteMediaCount: nostrService.noteMedia.count,
            wotCount: feedService.wotPubkeys.count,
            activeAccountNpub: configService.config.activeAccountNpub,
            onSelectedMediaChange: { isCopied = false },
            onScheduleUpdate: { scheduleUpdateDisplayData() },
            onAccountChange: {
                mediaHasLoadedOnce = false
                refreshAll()
            },
            onMirrorComplete: { loadLocalMedia(force: true) },
            onMediaNotFound: { scheduleUpdateDisplayData() },
            onBlossomDirectoryChanged: { loadLocalMedia(force: true) }
        )
    }

    /// Extracted sheets, overlays, and pickers to reduce type-checker complexity.
    var mediaSheetsAndPickers: MediaGallerySheetsModifier {
        MediaGallerySheetsModifier(
            selectedMedia: selectedMedia,
            isPresentingViewer: isPresentingViewer,
            showingProfilePubkey: $showingProfilePubkey,
            showingNoteId: $showingNoteId,
            showingBlossomMediaList: $showingBlossomMediaList,
            showingFileImporter: $showingFileImporter,
            showingPhotoPicker: $showingPhotoPicker,
            selectedUploadItems: $selectedUploadItems,
            photosPickerFilter: photosPickerFilter,
            mediaViewerContent: { item in AnyView(mediaViewerContent(for: item)) },
            fullScreenOverlay: { AnyView(fullScreenOverlay) },
            onUploadFiles: { handleUploadFileURLs($0) },
            onUploadItems: { items in
                handleUploadSelectedItems(items)
                showingPhotoPicker = false
            }
        )
    }
}

// MARK: - Magic Paste from the widget

/// Runs the Media tab's Magic Paste when the Mosaic widget's wand is tapped.
///
/// Its own modifier rather than a twelfth `onReceive` on
/// `MediaGalleryChangeHandlers`: that chain is already at the size where the
/// Swift type-checker starts refusing the file.
struct MagicPasteFromWidget: ViewModifier {
    let paste: () -> Void

    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: .havenMagicPaste)) { _ in
            paste()
        }
    }
}

// MARK: - MediaGalleryChangeHandlers

/// Extracted onChange / onReceive modifiers to reduce type-checker complexity in MediaGalleryView.
struct MediaGalleryChangeHandlers: ViewModifier {
    let selectedMedia: MediaItem?
    let mediaSourceFilter: MediaSourceFilter
    let mediaLocationFilter: MediaLocationFilter
    let mediaTypeFilter: Set<MediaTypeFilter>
    let sortOption: MediaSortOption
    let blossomItemsCount: Int
    let noteMediaCount: Int
    let wotCount: Int
    let activeAccountNpub: String

    let onSelectedMediaChange: () -> Void
    let onScheduleUpdate: () -> Void
    let onAccountChange: () -> Void
    let onMirrorComplete: () -> Void
    let onMediaNotFound: () -> Void
    let onBlossomDirectoryChanged: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: selectedMedia) { _, _ in onSelectedMediaChange() }
            .onChange(of: mediaSourceFilter) { _, _ in onScheduleUpdate() }
            .onChange(of: mediaLocationFilter) { _, _ in onScheduleUpdate() }
            .onChange(of: mediaTypeFilter) { _, _ in onScheduleUpdate() }
            .onChange(of: sortOption) { _, _ in onScheduleUpdate() }
            .onChange(of: blossomItemsCount) { _, _ in onScheduleUpdate() }
            .onChange(of: noteMediaCount) { _, _ in onScheduleUpdate() }
            .onChange(of: wotCount) { _, _ in onScheduleUpdate() }
            .onChange(of: activeAccountNpub) { _, _ in onAccountChange() }
            .onReceive(MirrorService.shared.$state) { newState in
                if newState == .complete { onMirrorComplete() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .mediaNotFoundChanged)) { _ in
                onMediaNotFound()
            }
            .onReceive(NotificationCenter.default.publisher(for: .blossomDirectoryChanged)) { _ in
                onBlossomDirectoryChanged()
            }
    }
}

// MARK: - MediaGallerySheetsModifier

/// Extracted sheets, overlays, file importers, and photo pickers to reduce type-checker complexity.
struct MediaGallerySheetsModifier: ViewModifier {
    let selectedMedia: MediaItem?
    let isPresentingViewer: Binding<Bool>
    @Binding var showingProfilePubkey: String?
    @Binding var showingNoteId: String?
    @Binding var showingBlossomMediaList: Bool
    @Binding var showingFileImporter: Bool
    @Binding var showingPhotoPicker: Bool
    @Binding var selectedUploadItems: [PhotosPickerItem]
    let photosPickerFilter: PHPickerFilter
    let mediaViewerContent: (MediaItem) -> AnyView
    let fullScreenOverlay: () -> AnyView
    let onUploadFiles: ([URL]) -> Void
    let onUploadItems: ([PhotosPickerItem]) -> Void

    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var configService: ConfigService

    func body(content: Content) -> some View {
        content
            #if os(iOS)
            .fullScreenCover(isPresented: isPresentingViewer) {
                if let item = selectedMedia {
                    mediaViewerContent(item)
                }
            }
            #else
            .overlay(fullScreenOverlay())
            #endif
            .sheet(item: Binding<IdentifiableString?>(
                get: { showingProfilePubkey.map { IdentifiableString(id: $0) } },
                set: { showingProfilePubkey = $0?.id }
            )) { p in
                ProfileView(pubkey: p.id, onDismiss: { showingProfilePubkey = nil })
            }
            .sheet(item: Binding<IdentifiableString?>(
                get: { showingNoteId.map { IdentifiableString(id: $0) } },
                set: { showingNoteId = $0?.id }
            )) { noteId in
                NoteDetailViewWrapper(noteId: noteId.id, onDismiss: { showingNoteId = nil })
                    .environmentObject(nostrService)
                    .environmentObject(configService)
            }
            .sheet(isPresented: $showingBlossomMediaList) {
                BlossomDashboardView()
                    .environmentObject(configService)
                    .environmentObject(nostrService)
                    #if os(macOS)
                    // Stats, mirrors, sync and the activity log need room; without a
                    // minimum the sheet takes the content's ideal size.
                    .frame(minWidth: 620, minHeight: 640)
                    #endif
            }
            .fileImporter(
                isPresented: $showingFileImporter,
                allowedContentTypes: [.image, .movie],
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    onUploadFiles(urls)
                case .failure(let error):
                    print("Failed to select files: \(error)")
                }
            }
            .photosPicker(
                isPresented: $showingPhotoPicker,
                selection: $selectedUploadItems,
                matching: photosPickerFilter
            )
            .onChange(of: selectedUploadItems) { _, items in
                if !items.isEmpty {
                    onUploadItems(items)
                }
            }
    }
}
