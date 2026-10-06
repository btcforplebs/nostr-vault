import SwiftUI
import Combine
import ImageIO
#if os(iOS)
import Photos
#endif

struct ProfileView: View {
    let pubkey: String
    var embeddedInNavigation: Bool = false
    var onDismiss: (() -> Void)? = nil

    @EnvironmentObject var nostrService: NostrService
    @StateObject private var feedService = FeedService.shared
    @StateObject private var dmService = DMService.shared
    @EnvironmentObject var configService: ConfigService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var showingNoteDetail: FeedNote?
    /// Non-nil when an iPad split pane owns the note detail column.
    @Environment(\.noteDetailSelection) private var noteDetailSelection
    /// True when this profile is a sheet or a pushed page. Sheets inherit the
    /// environment, so without this a profile opened over the split would
    /// select into the detail column hidden behind it.
    @Environment(\.isPresented) private var isPresented
    @State private var showingProfileKey: IdentifiableString?
    @State private var showingMediaUrl: IdentifiableURL?
    @Namespace private var mediaZoom
    @State private var selectedMedia: MediaItem? = nil
    @State private var dragOffset: CGSize = .zero
    #if os(iOS)
    @State private var saveToPhotosMessage: String? = nil
    #endif
    #if os(macOS)
    @State private var keyMonitor: Any? = nil
    #endif
    
    @State private var showSweep = false
    @State private var showLightning = false
    @State private var zapSheetContext: ZapSheetContext?
    @State private var copiedNpub = false
    @State private var copiedLightning = false

    // Edit profile
    @State private var showingEditProfile = false

    // Compose post
    @State private var showingCompose = false
    @State private var composeContext: ComposeContext?

    // Settings (iOS — accessed from toolbar)
    @State private var showingSettings = false

    // Message composer
    @State private var showingMessageComposer = false

    // DM inbox
    @State private var showingDMInbox = false

    // Wallet views
    @State private var showingLightning = false

    // Following / followers count
    @State private var followingCount: Int? = nil
    @State private var followsMe: Bool = false
    @State private var followersCount: Int? = nil
    @State private var followerPubkeys = Set<String>()

    // Note streaming
    @State private var profileNotes: [FeedNote] = []
    @State private var isLoadingNotes = false
    @State private var profileClients: [WebSocketClient] = []
    @State private var profileCancellables = Set<AnyCancellable>()
    @State private var seenNoteIds = Set<String>()
    @State private var isLoadingOlderNotes = false
    @State private var hasMoreNotes = true

    // Paging bookkeeping. A "page" is one round of `older-` REQs sent to every
    // connected relay under a single subscription id; it completes when they have
    // all answered (EOSE or CLOSED), or when the fallback timer fires — whichever
    // comes first. The token guards against a late timer finishing a newer page.
    @State private var olderPageToken = 0
    @State private var olderPageSubId: String? = nil
    @State private var olderPageAnswers = 0
    @State private var olderPageExpected = 0
    @State private var olderPageCountBefore = 0
    @State private var olderPageVisibleBefore = 0
    @State private var olderPageSection: ProfileSection = .notes
    @State private var quietOlderPages = 0
    @State private var autoPagedInARow = 0

    // Tagged notes (notes by others that tag/mention/repost/quote this user)
    @State private var taggedNotes: [FeedNote] = []
    @State private var seenTaggedIds = Set<String>()
    @State private var isLoadingOlderTaggedNotes = false
    @State private var hasMoreTaggedNotes = true
    @State private var olderTaggedToken = 0
    @State private var olderTaggedSubId: String? = nil
    @State private var olderTaggedAnswers = 0
    @State private var olderTaggedExpected = 0
    @State private var olderTaggedCountBefore = 0
    @State private var olderTaggedVisibleBefore = 0
    @State private var quietOlderTaggedPages = 0
    @State private var autoPagedTaggedInARow = 0

    // Total counts from local relay (own profile)
    @State private var totalNoteCount: Int? = nil
    @State private var totalMediaCount: Int? = nil

    @State private var selectedSection: ProfileSection = .notes

    /// Height of the profile's scroll view. A section is at least this tall,

    /// so picking one with a single item keeps the tabs where they were and

    /// leaves blank space below, instead of the page snapping back down.

    @State private var viewportHeight: CGFloat = 0
    /// Width of the scroll view; the banner's height follows it.
    @State private var viewportWidth: CGFloat = 0
    /// Height of the bars above the scroll view's content, which the banner
    /// reaches up under.
    @State private var topInset: CGFloat = 0
    @StateObject private var shop = SellerListingsLoader()
    /// This person's articles, diVines and music, each a tab when they have any.
    @StateObject private var extras = ProfileExtrasLoader()
    @State private var showingArticle: ArticleRoute?
    @State private var musicSheet: MusicSheet?
    @State private var showingSell = false
    @State private var selectedListing: MarketListing?

    enum ProfileSection: String, CaseIterable, Identifiable {
        case notes = "Notes"
        case media = "Media"
        case replies = "Replies"
        case articles = "Articles"
        case divines = "diVines"
        case music = "Music"
        case tagged = "Tagged"
        case shop = "Shop"
        var id: String { rawValue }

        /// The feed types' own icons, so a tab reads the same as the feed it
        /// matches. Tabs are icons only; the name is the accessibility label
        /// and, on the Mac, the tooltip.
        var symbol: String {
            switch self {
            case .notes: return "text.bubble"
            case .media: return FeedMode.media.symbolName
            case .replies: return "arrowshape.turn.up.left"
            case .articles: return FeedMode.articles.symbolName
            case .divines: return FeedMode.reels.symbolName
            case .music: return FeedMode.music.symbolName
            case .tagged: return "at"
            case .shop: return FeedMode.marketplace.symbolName
            }
        }
    }

    private var isOwnProfile: Bool {
        configService.activeAccountHexPubkey == pubkey
    }

    // NWC wallet belongs to the owner only — don't re-fetch balance for whitelisted accounts.
    private var isOwnerProfile: Bool {
        Bech32.decode(configService.config.ownerNpub)?.hexString == pubkey
    }

    private var isFollowing: Bool {
        feedService.followedPubkeys.contains(pubkey)
    }

    private var isBlocked: Bool {
        guard let data = Data(hex: pubkey),
              let npub = Bech32.encode(hrp: "npub", data: data) else { return false }
        let active = configService.config.activeAccountNpub.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetNpub = active.isEmpty ? configService.config.ownerNpub : active
        let blockedList = configService.config.blockedNpubsPerAccount[targetNpub] ?? []
        return blockedList.contains(npub)
    }

    private var isThrottled: Bool {
        guard let data = Data(hex: pubkey),
              let npub = Bech32.encode(hrp: "npub", data: data) else { return false }
        let active = configService.config.activeAccountNpub.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetNpub = active.isEmpty ? configService.config.ownerNpub : active
        let throttledList = configService.config.throttledAccountsPerAccount[targetNpub] ?? [:]
        return throttledList[npub] != nil
    }

    private var profile: FeedProfile? {
        nostrService.profiles[pubkey]
    }

    private var defaultZapSats: Int {
        max(1, ConfigService.shared.config.defaultZapAmount / 1000)
    }

    // MARK: - Ordering

    /// A TOTAL order: newest first, ties broken by id. Sorting on the timestamp
    /// alone leaves same-second notes in arrival order, which reshuffles on every
    /// event that lands, and makes `profileNotes.last` — the anchor every `until`
    /// page is built on — an arbitrary member of the tie group. At a page boundary
    /// that drops one note and re-requests another.
    private static func newestFirst(_ a: FeedNote, _ b: FeedNote) -> Bool {
        if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
        return a.id > b.id
    }

    // MARK: - Filtered notes for tabs

    private var topNotes: [FeedNote] {
        profileNotes.filter { !$0.isReply }
    }

    private var mediaNotes: [FeedNote] {
        profileNotes.filter { !$0.mediaURLs.isEmpty && !$0.isReply }
    }

    private var replyNotes: [FeedNote] {
        profileNotes.filter { $0.isReply }
    }

    private var taggedFilteredNotes: [FeedNote] {
        taggedNotes.filter { $0.pubkey != pubkey }
    }

    private var currentSectionNotes: [FeedNote] {
        switch selectedSection {
        case .notes: return topNotes
        case .media: return mediaNotes
        case .replies: return replyNotes
        case .tagged: return taggedFilteredNotes
        case .shop, .articles, .divines, .music: return []
        }
    }

    private var displayMedia: [MediaItem] {
        let items: [(url: URL, note: FeedNote)] = mediaNotes.flatMap { note in
            note.mediaURLs.map { (url: $0, note: note) }
        }
        return items.map { item in
            let ext = item.url.pathExtension.lowercased()
            var isGIF = ext == "gif"
            var isVideo = SupportedMediaFormats.videoExtensions.contains(ext)
            var isAudio = SupportedMediaFormats.audioExtensions.contains(ext)
            
            if let cachedMime = MediaTypeDetector.shared.getCachedContentType(for: item.url) {
                isGIF = MediaTypeDetector.shared.isGIFContentType(cachedMime)
                isVideo = MediaTypeDetector.shared.isVideoContentType(cachedMime)
                isAudio = cachedMime.lowercased().hasPrefix("audio/")
            }
            
            let type: MediaItem.MediaType = isVideo ? .video : (isAudio ? .audio : .image)
            let mime = isGIF ? "image/gif" : (isVideo ? "video/mp4" : nil)
            
            return MediaItem(
                id: UUID.deterministic(from: item.url.absoluteString),
                url: item.url,
                type: type,
                dateAdded: item.note.createdAt,
                pubkey: item.note.pubkey,
                tags: item.note.tags,
                mimeType: mime
            )
        }
    }

    private var isPresentingViewer: Binding<Bool> {
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

    private var sectionCount: (notes: Int, media: Int, replies: Int, tagged: Int) {
        let notes = (isOwnProfile ? totalNoteCount : nil) ?? topNotes.count
        let media = (isOwnProfile ? totalMediaCount : nil) ?? mediaNotes.count
        return (notes, media, replyNotes.count, taggedFilteredNotes.count)
    }

    /// Opens a note in the split pane's detail column when this profile is the
    /// pane's list, and falls back to the sheet everywhere else.
    private func openNote(_ note: FeedNote) {
        if let noteDetailSelection, !isPresented {
            noteDetailSelection.select(note)
        } else {
            showingNoteDetail = note
        }
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                bannerHeader
                VStack(spacing: 0) {
                    headerBlock
                    actionRow
                        .padding(.top, 4)
                    if let about = profile?.about, !about.isEmpty {
                        bioBlock(about)
                    }
                    divider
                    statsBlock
                    divider
                    identityBlock
                    divider
                    sectionTabBar
                    sectionContent
                        .environment(\.feedActions, .make(feedService: feedService, nostrService: nostrService))
                        .tabBarBottomPadding()
                        .frame(minHeight: viewportHeight, alignment: .top)
                }
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
        }
        .scrollDirectionTracking(feedService: feedService)
        .onGeometryChange(for: CGSize.self) { $0.size } action: {
            viewportHeight = $0.height
            viewportWidth = $0.width
        }
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { topInset = $0 }
        // The banner draws its own scrim under the bar; the system edge would
        // lay a grey band over it.
        .hiddenTopScrollEdge()
        .if(isOwnProfile) { view in
            view.refreshable {
                await refreshProfile()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.platformWindowBackground.ignoresSafeArea())
        .onAppear {
            nostrService.fetchMissingProfiles(for: [pubkey])
            fetchAuthorNotes()
            fetchLocalRelayCounts()
            shop.load(pubkey: pubkey)
            extras.load(pubkey: pubkey, relays: extrasRelays)
            #if os(macOS)
            installKeyMonitor()
            #endif
        }
        .onDisappear {
            disconnectClients()
            #if os(macOS)
            removeKeyMonitor()
            #endif
        }
        .sheet(isPresented: $showingSell, onDismiss: { shop.load(pubkey: pubkey, force: true) }) {
            MarketplaceSellView(onDismiss: { showingSell = false })
                .environmentObject(nostrService)
                .environmentObject(configService)
        }
        .sheet(item: $showingArticle) { route in
            // In a stack so a comment under the article can open as a note.
            NavigationStack {
                ArticleReaderView(note: route.note)
            }
            .environmentObject(nostrService)
            .environmentObject(configService)
            #if os(macOS)
            .frame(minWidth: 520, minHeight: 480)
            #endif
        }
        .modifier(MusicSheetHost(sheet: $musicSheet))
        .environmentObject(RelayProcessManager.shared)
        .sheet(item: $selectedListing) { listing in
            MarketplaceListingSheet(listing: listing)
                .environmentObject(nostrService)
        }
        .sheet(item: $showingNoteDetail) { note in
            NavigationStack {
                NoteDetailView(note: note)
                    .navigationDestination(for: FeedNote.self) { detailNote in
                        NoteDetailView(note: detailNote)
                    }
            }
            #if os(macOS)
            .frame(minWidth: 520, minHeight: 560)
            #endif
        }
        .sheet(item: $showingProfileKey) { p in
            ProfileView(pubkey: p.id, onDismiss: { showingProfileKey = nil })
                .environmentObject(nostrService)
                .environmentObject(configService)
                #if os(macOS)
                // A macOS sheet with no minimum inherits its content's ideal size and can
                // open too small to use.
                .frame(minWidth: 520, minHeight: 560)
                #endif
        }
        .mediaViewer(item: $showingMediaUrl, namespace: mediaZoom)
        .hashtagLinks()
        .sheet(isPresented: $showSweep) {
            BitcoinSweepDisclaimerView(onDismiss: { showSweep = false })
                .environmentObject(ConfigService.shared)
        }
        .sheet(isPresented: $showingLightning) {
            NavigationStack {
                WalletLightningTab()
                    .environmentObject(nostrService)
                    .environmentObject(configService)
                    .navigationTitle("Lightning")
                    #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    #endif
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { showingLightning = false }
                                .foregroundColor(.havenPurple)
                        }
                    }
            }
            #if os(macOS)
            .frame(minWidth: 500, minHeight: 550)
            #endif
        }
        .sheet(isPresented: $showingCompose) {
            ComposeView(onDismiss: { showingCompose = false })
                .environmentObject(nostrService)
                .environmentObject(configService)
        }
        .sheet(item: $composeContext) { ctx in
            ComposeView(onDismiss: { composeContext = nil }, replyTo: ctx.replyTo, quoteTo: ctx.quoteTo, initialContent: ctx.initialContent, restoredDraftId: ctx.draftId)
                .environmentObject(nostrService)
                .environmentObject(configService)
        }
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                if isOwnProfile {
                    HStack(spacing: 16) {
                        if isOwnerProfile {
                            Button(action: { showingLightning = true }) {
                                Image(systemName: "bolt.fill")
                                    .font(.appSystem(size: 16, weight: .semibold))
                                    .foregroundColor(.havenPurple)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                if isOwnProfile {
                    HStack(spacing: 16) {
                        Button(action: { showingDMInbox = true }) {
                            Image(systemName: "bubble.right.fill")
                                .font(.appSystem(size: 16, weight: .semibold))
                                .foregroundColor(.havenPurple)
                                .overlay(alignment: .topTrailing) {
                                    if dmService.totalUnreadCount > 0 {
                                        Circle()
                                            .fill(.red)
                                            .frame(width: 8, height: 8)
                                            .offset(x: 3, y: -3)
                                    }
                                }
                        }
                        .buttonStyle(.plain)

                        Button(action: { showingSettings = true }) {
                            Image(systemName: "gearshape.fill")
                                .font(.appSystem(size: 16, weight: .semibold))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    Button(action: { showingMessageComposer = true }) {
                        Image(systemName: "message.fill")
                            .font(.appSystem(size: 16, weight: .semibold))
                            .foregroundColor(.havenPurple)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .sheet(isPresented: $showingMessageComposer) {
            MessageComposerView(recipientPubkey: pubkey)
                .environmentObject(nostrService)
                .environmentObject(configService)
        }
        .sheet(isPresented: $showingDMInbox) {
            NavigationStack {
                DMInboxView()
                    .environmentObject(nostrService)
                    .environmentObject(configService)
            }
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                SettingsView()
                    .environmentObject(RelayProcessManager.shared)
                    .environmentObject(ConfigService.shared)
                    .environmentObject(NostrService.shared)
                    .environmentObject(StatsService.shared)
                    .navigationTitle("Settings")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { showingSettings = false }
                                .foregroundColor(.havenPurple)
                        }
                    }
            }
        }
        #else
        .toolbar {
            ToolbarItem(placement: .automatic) {
                if isOwnProfile {
                    // `.refreshable` on the scroll view is the profile's only refresh
                    // path, and macOS has no pull-to-refresh to reach it.
                    Button(action: { Task { await refreshProfile() } }) {
                        Image(systemName: "arrow.clockwise")
                            .foregroundColor(.havenPurple)
                    }
                    .help("Refresh Profile")
                    .keyboardShortcut("r", modifiers: .command)
                }
            }
            ToolbarItem(placement: .automatic) {
                if isOwnerProfile {
                    Button(action: { showingLightning = true }) {
                        Image(systemName: "bolt.fill")
                            .foregroundColor(.havenPurple)
                    }
                    .help("Lightning")
                }
            }
            ToolbarItem(placement: .automatic) {
                if isOwnProfile {
                    Button(action: { showingDMInbox = true }) {
                        Image(systemName: "bubble.right.fill")
                            .foregroundColor(.havenPurple)
                            .overlay(alignment: .topTrailing) {
                                if dmService.totalUnreadCount > 0 {
                                    Circle()
                                        .fill(.red)
                                        .frame(width: 7, height: 7)
                                        .offset(x: 2, y: -2)
                                }
                            }
                    }
                    .help("Messages")
                }
            }
        }
        .sheet(isPresented: $showingDMInbox) {
            DMInboxView()
                .environmentObject(nostrService)
                .environmentObject(configService)
                .frame(minWidth: 480, minHeight: 500)
        }
        .sheet(isPresented: $showingMessageComposer) {
            DMThreadView(counterpartyPubkey: pubkey)
                .environmentObject(nostrService)
                .environmentObject(configService)
                .frame(minWidth: 440, minHeight: 400)
        }
        #endif
        .sheet(isPresented: $showingEditProfile) {
            ProfileEditView(onDismiss: { showingEditProfile = false }, existing: profile ?? FeedProfile(pubkey: pubkey)) { updated in
                applyProfileUpdate(updated)
            }
            .environmentObject(nostrService)
        }
        #if os(macOS)
        // On iPhone and iPad every banner is drawn in its own window above all
        // sheets (BannerWindow in SceneDelegate), so a profile sheet cannot
        // cover one; the Mac still draws them over the sheet itself.
        .overlay(alignment: .top) {
            if onDismiss != nil {
                VStack(spacing: 6) {
                    FollowNotificationBanner()
                    ZapNotificationBanner()
                    ErrorNotificationBanner()
                }
                .padding(.top, 4)
                .allowsHitTesting(true)
            }
        }
        #endif
        #if os(iOS)
        .overlay(alignment: .bottomTrailing) {
            if isOwnProfile {
                ChromeFold(anchor: .bottomTrailing) {
                    Button(action: { showingCompose = true }) {
                        HStack(spacing: 6) {
                            Image(systemName: "square.and.pencil")
                                .font(.appSystem(size: 15, weight: .bold))
                            Text("Post")
                                .font(.appSystem(size: 14, weight: .bold, design: .rounded))
                        }
                        .foregroundColor(.white)
                        .frame(height: 48)
                        .padding(.horizontal, 18)
                        .background(
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        gradient: Gradient(colors: [Color.havenPurple, Color.havenPurpleLight]),
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .shadow(color: Color.havenPurple.opacity(0.35), radius: 8, x: 0, y: 4)
                        )
                    }
                    .buttonStyle(PressScaleButtonStyle())
                    // Shares the row above the tab bar with the music mini player.
                    .modifier(FloatingButtonSlot())
                    .hoverEffect(.lift)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .composeFromTabBar)) { note in
            guard (note.object as? Int) == 2 else { return }
            showingCompose = true
        }
        .fullScreenCover(isPresented: isPresentingViewer) {
            if let item = selectedMedia {
                mediaViewerContent(for: item)
            }
        }
        #else
        .overlay(fullScreenOverlay)
        #endif
        .sheet(item: $zapSheetContext) { context in
            CustomZapSheet(defaultAmount: context.defaultAmount) { amount in
                if let lud16 = lightningAddress {
                    Task { await zapProfile(lud16: lud16, amount: amount) }
                }
            }
            #if os(iOS)
            .presentationDetents([.height(380), .medium])
            .presentationDragIndicator(.visible)
            .presentationBackground(Color.platformWindowBackground)
            #endif
        }
    }

    // MARK: - Dismiss header (sheet context only)

    private var showsDismissButton: Bool {
        !embeddedInNavigation && (!isOwnProfile || onDismiss != nil)
    }

    /// Sits on the banner, so it carries its own dark disc instead of relying
    /// on the page behind it.
    private var dismissHeader: some View {
        HStack {
            Spacer()
            Button(action: { performDismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.appSystem(size: 24))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white.opacity(0.9), .black.opacity(0.45))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    // MARK: - Banner

    /// A profile with a banner gets a strip a third as tall as it is wide;
    /// one without gets a short tinted wash, so the avatar still has something
    /// to sit on and the page has no gray block at the top.
    private var bannerHeight: CGFloat {
        guard profile?.bannerURL != nil else { return 64 }
        let width = viewportWidth > 0 ? viewportWidth : 390
        return min(max(width / 3, 110), 210)
    }

    private var bannerHeader: some View {
        ProfileBannerView(
            bannerURL: profile?.bannerURL,
            avatarURL: profile?.pictureURL,
            pubkey: pubkey,
            height: bannerHeight,
            topInset: topInset,
            onTap: { url in showingMediaUrl = IdentifiableURL(url: url) }
        )
        .overlay(alignment: .top) {
            if showsDismissButton { dismissHeader }
        }
        .animation(Motion.panel, value: bannerHeight)
    }

    private func performDismiss() {
        if let onDismiss = onDismiss {
            onDismiss()
        } else {
            dismiss()
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.platformSeparator.opacity(0.6))
            .frame(height: 0.5)
            .padding(.vertical, 16)
    }

    // MARK: - Header block

    private var headerBlock: some View {
        HStack(alignment: .top, spacing: 14) {
            AvatarView(url: profile?.pictureURL, pubkey: pubkey, size: 72)
                .overlay(
                    Circle().stroke(Color.havenPurple.opacity(0.35), lineWidth: 1.5)
                )
                // A ring in the page color lifts the avatar off the banner.
                .padding(3)
                .background(Circle().fill(Color.platformWindowBackground))
                // Half over the banner; the name column stays below it.
                .padding(.top, -36)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(profile?.bestName ?? shortPubkey)
                        .font(.appSystem(size: 20, weight: .bold))
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    if let nip05 = profile?.nip05, !nip05.isEmpty {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.appSystem(size: 13))
                            .foregroundColor(Color.havenVerified)
                    }

                    Spacer(minLength: 0)

                    statusBadge
                }

                if let nip05 = profile?.nip05, !nip05.isEmpty {
                    Text(nip05)
                        .font(.appSystem(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Button(action: copyNpub) {
                    HStack(spacing: 5) {
                        Text(formattedNpub)
                            .font(.appSystem(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                        Image(systemName: copiedNpub ? "checkmark" : "doc.on.doc")
                            .font(.appSystem(size: 9))
                            .foregroundColor(copiedNpub ? .green : .secondary.opacity(0.6))
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(copiedNpub ? "Public key copied" : "Copy public key")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    @ViewBuilder
    private var statusBadge: some View {
        if isOwnProfile {
            Text("YOU")
                .font(.appSystem(size: 9, weight: .heavy))
                .tracking(0.8)
                .foregroundColor(.havenPurple)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.havenPurple.opacity(0.15))
                .cornerRadius(4)
        } else if isFollowing && followsMe {
            HStack(spacing: 3) {
                Text("∞")
                    .font(.appSystem(size: 13, weight: .black))
                Text("MUTUAL")
                    .font(.appSystem(size: 9, weight: .heavy))
                    .tracking(0.8)
            }
            .foregroundColor(Color.havenVerified)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.havenVerified.opacity(0.13))
            .cornerRadius(4)
        } else {
            HStack(spacing: 4) {
                if isFollowing {
                    Text("FOLLOWING")
                        .font(.appSystem(size: 9, weight: .heavy))
                        .tracking(0.8)
                        .foregroundColor(.green)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.green.opacity(0.15))
                        .cornerRadius(4)
                }
                if followsMe {
                    Text("FOLLOWS YOU")
                        .font(.appSystem(size: 9, weight: .heavy))
                        .tracking(0.8)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.12))
                        .cornerRadius(4)
                }
            }
        }
    }

    // MARK: - Bio

    private func bioBlock(_ about: String) -> some View {
        Text(about)
            .font(.appSystem(size: 13))
            .foregroundColor(.primary.opacity(0.85))
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 12)
    }

    // MARK: - Action row

    @ViewBuilder
    private var actionRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                if isOwnProfile {
                Button(action: { showingCompose = true }) {
                    HStack(spacing: 6) {
                        Image(systemName: "pencil")
                            .font(.appSystem(size: 12, weight: .semibold))
                        Text("Post")
                            .font(.appSystem(size: 13, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color.havenPurple)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)

                Button(action: { showingEditProfile = true }) {
                    HStack(spacing: 6) {
                        Image(systemName: "person.crop.circle")
                            .font(.appSystem(size: 12, weight: .semibold))
                        Text("Edit")
                            .font(.appSystem(size: 13, weight: .semibold))
                    }
                    .foregroundColor(.havenPurple)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color.havenPurple.opacity(0.12))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
            } else {
                Button(action: toggleFollow) {
                    HStack(spacing: 6) {
                        Image(systemName: isFollowing ? "person.badge.minus" : "person.badge.plus")
                            .font(.appSystem(size: 12, weight: .semibold))
                        Text(isFollowing ? "Unfollow" : "Follow")
                            .font(.appSystem(size: 13, weight: .semibold))
                    }
                    .foregroundColor(isFollowing ? .white : .havenPurple)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(isFollowing ? Color.havenPurple : Color.havenPurple.opacity(0.12))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isFollowing ? "Unfollow" : "Follow")

                Button(action: { showingMessageComposer = true }) {
                    HStack(spacing: 6) {
                        Image(systemName: "message.fill")
                            .font(.appSystem(size: 12, weight: .semibold))
                        Text("Message")
                            .font(.appSystem(size: 13, weight: .semibold))
                    }
                    .foregroundColor(.havenPurple)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color.havenPurple.opacity(0.12))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)

                Button(action: toggleBlock) {
                    HStack(spacing: 6) {
                        Image(systemName: isBlocked ? "hand.raised.slash" : "hand.raised")
                            .font(.appSystem(size: 12, weight: .semibold))
                        Text(isBlocked ? "Unblock" : "Block")
                            .font(.appSystem(size: 13, weight: .semibold))
                    }
                    .foregroundColor(isBlocked ? .orange : .red)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background((isBlocked ? Color.orange : Color.red).opacity(0.12))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isBlocked ? "Unblock user" : "Block user")

                Button(action: toggleThrottle) {
                    HStack(spacing: 6) {
                        Image(systemName: isThrottled ? "gauge.open.with.lines.needle.33percent" : "gauge")
                            .font(.appSystem(size: 12, weight: .semibold))
                        Text(isThrottled ? "Speed Up" : "Slow Down")
                            .font(.appSystem(size: 13, weight: .semibold))
                    }
                    .foregroundColor(isThrottled ? .blue : .secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background((isThrottled ? Color.blue : Color.secondary).opacity(0.12))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isThrottled ? "Remove speed limit" : "Slow down posts")

                if !ConfigService.shared.config.nwcURI.isEmpty, lightningAddress != nil {
                    HStack(spacing: 5) {
                        Image(systemName: "bolt.fill")
                            .font(.appSystem(size: 12, weight: .semibold))
                        Text("Zap \(defaultZapSats)")
                            .font(.appSystem(size: 13, weight: .semibold))
                    }
                    .foregroundColor(.orange)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color.orange.opacity(0.15))
                    .cornerRadius(6)
                    .overlay { ZapBurstView(isAnimating: $showLightning) }
                    .contentShape(RoundedRectangle(cornerRadius: 6))
                    .onLongPressGesture {
                        #if os(iOS)
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        #endif
                        zapSheetContext = ZapSheetContext(defaultAmount: defaultZapSats)
                    }
                    .onTapGesture {
                        if let lud16 = lightningAddress {
                            Task { await zapProfile(lud16: lud16) }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        }
    }

    // MARK: - Stats block

    private var statsBlock: some View {
        HStack(spacing: 0) {
            statCell(value: shortInt(sectionCount.notes), label: "NOTES")
            statDivider
            statCell(value: shortInt(sectionCount.media), label: "MEDIA")
            statDivider
            if isOwnProfile {
                statCell(
                    value: shortInt(feedService.followedPubkeys.filter { $0 != pubkey }.count),
                    label: "FOLLOWING"
                )
            } else {
                statCell(
                    value: followingCount.map(shortInt) ?? "—",
                    label: "FOLLOWING"
                )
                statDivider
                statCell(
                    value: followersCount.map(shortInt) ?? "∞",
                    label: "FOLLOWERS",
                    tint: followersCount == nil ? Color.havenVerified.opacity(0.55) : .primary
                )
            }
        }
        .padding(.horizontal, 16)
    }

    private var statDivider: some View {
        Rectangle()
            .fill(Color.platformSeparator.opacity(0.4))
            .frame(width: 0.5)
            .padding(.vertical, 10)
    }

    private func statCell(value: String, label: String, tint: Color = .primary) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.appSystem(size: 18, weight: .bold, design: .monospaced))
                .foregroundColor(tint)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(label)
                .font(.appSystem(size: 9, weight: .semibold))
                .tracking(0.6)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    // MARK: - Identity block (table-style rows)

    @ViewBuilder
    private var identityBlock: some View {
        VStack(spacing: 0) {
            if let lud16 = lightningAddress {
                identityRow(
                    label: "LIGHTNING",
                    value: lud16,
                    icon: "bolt.fill",
                    tint: .orange,
                    copied: copiedLightning,
                    trailing: zapInlineButton(lud16: lud16),
                    action: { copyToClipboard(lud16); triggerCopied($copiedLightning) }
                )
            }

            if let website = profile?.website, !website.isEmpty,
               let url = URL(string: website.hasPrefix("http") ? website : "https://\(website)") {
                identityDivider
                Button(action: { openURL(url) }) {
                    identityRowContent(
                        label: "WEBSITE",
                        value: website.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: ""),
                        icon: "globe",
                        tint: .havenPurple,
                        copied: false,
                        trailing: AnyView(
                            Image(systemName: "arrow.up.right.square")
                                .font(.appSystem(size: 13, weight: .semibold))
                                .foregroundColor(.havenPurple)
                        )
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var identityDivider: some View {
        Rectangle()
            .fill(Color.platformSeparator.opacity(0.4))
            .frame(height: 0.5)
            .padding(.leading, 16)
    }

    private func zapInlineButton(lud16: String) -> AnyView {
        if isOwnerProfile {
            return AnyView(EmptyView())
        }
        guard !ConfigService.shared.config.nwcURI.isEmpty else { return AnyView(EmptyView()) }
        return AnyView(
            HStack(spacing: 3) {
                Image(systemName: "bolt.fill")
                    .font(.appSystem(size: 10, weight: .bold))
                Text("\(defaultZapSats)")
                    .font(.appSystem(size: 11, weight: .bold, design: .monospaced))
            }
            .foregroundColor(.orange)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.orange.opacity(0.15))
            .cornerRadius(4)
            .overlay { ZapBurstView(isAnimating: $showLightning) }
            .contentShape(RoundedRectangle(cornerRadius: 4))
            .onLongPressGesture {
                #if os(iOS)
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                #endif
                zapSheetContext = ZapSheetContext(defaultAmount: defaultZapSats)
            }
            .onTapGesture {
                Task { await zapProfile(lud16: lud16) }
            }
        )
    }

    /// `trailing` (the zap pill) sits beside the copy button, not in its label,
    /// so a click on the pill can only ever zap, never also copy the address.
    private func identityRow(label: String, value: String, icon: String, tint: Color, copied: Bool, trailing: AnyView, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Button(action: action) {
                identityRowContent(label: label, value: value, icon: icon, tint: tint, copied: copied, trailing: AnyView(EmptyView()), trailingPadding: 0)
            }
            .buttonStyle(.plain)
            trailing
        }
        .padding(.trailing, 16)
    }

    private func identityRowContent(label: String, value: String, icon: String, tint: Color, copied: Bool, trailing: AnyView, trailingPadding: CGFloat = 16) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.appSystem(size: 13, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.appSystem(size: 9, weight: .heavy))
                    .tracking(0.8)
                    .foregroundColor(.secondary)
                Text(value)
                    .font(.appSystem(size: 13, design: .monospaced))
                    .foregroundColor(.primary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if copied {
                Image(systemName: "checkmark")
                    .font(.appSystem(size: 11, weight: .bold))
                    .foregroundColor(.green)
            }

            trailing
        }
        .padding(.leading, 16)
        .padding(.trailing, trailingPadding)
        .padding(.vertical, 10)
        // A plain button on macOS only takes clicks on drawn pixels; without
        // this the Spacer gap and the padding ignored clicks.
        .contentShape(Rectangle())
    }

    // MARK: - Section tab bar

    private var sectionTabBar: some View {
        HStack(spacing: 0) {
            ForEach(visibleSections) { section in
                Button(action: {
                    // No animation: the old and new sections cross-faded at
                    // different heights, and the page jumped while they did.
                    var instant = Transaction()
                    instant.disablesAnimations = true
                    withTransaction(instant) { selectedSection = section }
                }) {
                    VStack(spacing: 6) {
                        // Icons only, no names (Logen): icon and count, or the
                        // icon alone on a tab too narrow for the count.
                        ViewThatFits(in: .horizontal) {
                            tabLabel(section, showsCount: true)
                            tabLabel(section, showsCount: false)
                        }
                        .foregroundColor(selectedSection == section ? .havenPurple : .secondary)

                        Rectangle()
                            .fill(selectedSection == section ? Color.havenPurple : Color.clear)
                            .frame(height: 2)
                    }
                    .padding(.top, 4)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(section.rawValue))
                .accessibilityValue(Text(countLabel(for: section)))
                #if os(macOS)
                .help(section.rawValue)
                #endif
            }
        }
        .padding(.horizontal, 16)
    }

    private func tabLabel(_ section: ProfileSection, showsCount: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: section.symbol)
                .font(.appSystem(size: 14, weight: .semibold))
            let count = countLabel(for: section)
            if showsCount, !count.isEmpty {
                Text(count)
                    .font(.appSystem(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .lineLimit(1)
        .fixedSize()
        .frame(height: 20)
    }

    /// Shop only shows when this person has listings, or on your own profile
    /// where it holds the Sell button, so most profiles keep four tabs.
    private var visibleSections: [ProfileSection] {
        ProfileSection.allCases.filter { section in
            switch section {
            case .shop: return isOwnProfile || !shop.listings.isEmpty
            // Only when this person has some, so most profiles keep four tabs.
            case .articles: return !extras.articles.isEmpty
            case .divines: return !extras.reels.isEmpty
            case .music: return !extras.tracks.isEmpty
            default: return true
            }
        }
    }

    private func count(for section: ProfileSection) -> Int {
        switch section {
        case .shop: return shop.listings.count
        case .articles: return extras.articles.count
        case .divines: return extras.reels.count
        case .music: return extras.tracks.count
        case .notes: return sectionCount.notes
        case .media: return sectionCount.media
        case .replies: return sectionCount.replies
        case .tagged: return sectionCount.tagged
        }
    }

    private func countLabel(for section: ProfileSection) -> String {
        let n = count(for: section)
        return n > 0 ? shortInt(n) : ""
    }

    // MARK: - Section content

    @ViewBuilder
    private var sectionContent: some View {
        switch selectedSection {
        case .shop: shopSection
        case .articles: articlesSection
        case .divines: divinesSection
        case .music: musicSection
        default: noteSectionContent
        }
    }

    // MARK: - Articles, diVines, music

    /// Where this person's articles and diVines are likely to be: the relays
    /// the profile reads, their outbox, and diVine's own relay.
    private var extrasRelays: [URL] {
        var strings: [String] = []
        if RelayProcessManager.shared.isRunning && !RelayProcessManager.shared.isBooting {
            strings.append(configService.config.nostrURL)
        }
        let feedRelays = configService.config.activeFeedRelays
        strings += (feedRelays.isEmpty ? ["wss://relay.primal.net", "wss://relay.nos.social"] : feedRelays).prefix(3)
        strings += (nostrService.outboxRelays[pubkey] ?? []).prefix(3)
        strings.append(ReelsFeedService.divineRelay)
        var seen = Set<String>()
        return strings.filter { seen.insert($0).inserted }.compactMap { URL(string: $0) }
    }

    private var articlesSection: some View {
        LazyVStack(spacing: 12) {
            ForEach(extras.articles) { article in
                ArticleCardView(note: article, profile: profile)
                    .contentShape(Rectangle())
                    .onTapGesture { showingArticle = ArticleRoute(note: article) }
            }
        }
        .padding(16)
    }

    private var divinesSection: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 4)], spacing: 4) {
            ForEach(extras.reels) { reel in
                ZStack(alignment: .bottomLeading) {
                    Color.black
                    if let poster = reel.posterURL {
                        RetryableAsyncImage(url: poster, contentMode: .fill, targetSize: CGSize(width: 300, height: 530))
                    } else {
                        VideoThumbnailView(url: reel.videoURL, mimeType: reel.mimeType)
                    }
                    Image(systemName: "play.fill")
                        .font(.appSystem(size: 12, weight: .bold))
                        .foregroundColor(.white)
                        .shadow(radius: 3)
                        .padding(6)
                }
                .aspectRatio(9.0 / 16.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
                .onTapGesture {
                    let urls = extras.reels.map(\.videoURL)
                    showingMediaUrl = IdentifiableURL(url: reel.videoURL, allURLs: urls)
                }
                .accessibilityLabel(Text(reel.title ?? "diVine"))
                .accessibilityAddTraits(.isButton)
            }
        }
        .padding(16)
    }

    private var musicSection: some View {
        MusicTrackList(tracks: extras.tracks, sheet: $musicSheet)
            .padding(16)
    }

    @ViewBuilder
    private var shopSection: some View {
        VStack(spacing: 14) {
            if isOwnProfile {
                Button { showingSell = true } label: {
                    Label("Sell something", systemImage: "tag")
                        .font(.appSystem(size: 14, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(Color.havenPurple)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            if shop.listings.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: sectionEmptyIcon)
                        .font(.appSystem(size: 24, weight: .thin))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text(shop.isLoading ? "Loading…" : (isOwnProfile ? "You haven't listed anything yet" : "Nothing for sale"))
                        .font(.appSystem(size: 12))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 36)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    ForEach(shop.listings) { listing in
                        MarketplaceCardView(listing: listing, profile: profile)
                            .onTapGesture { selectedListing = listing }
                    }
                }
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private var noteSectionContent: some View {
        let notes = currentSectionNotes
        if notes.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: sectionEmptyIcon)
                    .font(.appSystem(size: 24, weight: .thin))
                    .foregroundColor(.secondary.opacity(0.5))
                Text(isLoadingNotes ? "Loading…" : "No \(selectedSection.rawValue.lowercased()) yet")
                    .font(.appSystem(size: 12))
                    .foregroundColor(.secondary)
                if isLoadingNotes {
                    ProgressView()
                        .scaleEffect(0.6)
                        .tint(Color.havenPurple)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 48)
        } else if selectedSection == .media {
            mediaGrid(notes: notes)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(Array(notes.enumerated()), id: \.element.id) { idx, note in
                    if idx > 0 {
                        Rectangle()
                            .fill(Color.platformSeparator.opacity(0.4))
                            .frame(height: 0.5)
                            .padding(.leading, 16)
                    }
                    FeedNoteRow(
                        note: note,
                        profile: selectedSection == .tagged
                            ? nostrService.profiles[note.pubkey]
                            : profile,
                        rowData: FeedNoteRowData.resolve(
                            for: note,
                            feedService: feedService,
                            nostrService: nostrService
                        ),
                        onReply: {
                            if note.kind == 6, let refId = note.repostedEventId,
                               let original = feedService.findNote(id: refId) {
                                composeContext = ComposeContext(replyTo: original, quoteTo: nil)
                            } else {
                                composeContext = ComposeContext(replyTo: note, quoteTo: nil)
                            }
                        },
                        onQuote: {
                            composeContext = ComposeContext(replyTo: nil, quoteTo: feedService.quoteTarget(for: note))
                        },
                        onProfile: { pubkey in
                            showingProfileKey = IdentifiableString(id: pubkey)
                        },
                        onMedia: { url, urls in
                            showingMediaUrl = IdentifiableURL(url: url, allURLs: urls)
                        },
                        showParent: false
                    )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            openNote(note)
                        }
                }

                // Infinite scroll sentinel
                let hasMore = selectedSection == .tagged ? hasMoreTaggedNotes : hasMoreNotes
                if hasMore && !notes.isEmpty {
                    Color.clear
                        .frame(height: 1)
                        .onAppear {
                            if selectedSection == .tagged {
                                loadOlderTaggedNotes()
                            } else {
                                loadOlderProfileNotes()
                            }
                        }
                    if (selectedSection == .tagged ? isLoadingOlderTaggedNotes : isLoadingOlderNotes) {
                        ProgressView()
                            .scaleEffect(0.6)
                            .tint(Color.havenPurple)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    private func mediaGrid(notes: [FeedNote]) -> some View {
        #if os(macOS)
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)
        let gridSpacing: CGFloat = 8
        #else
        let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)
        let gridSpacing: CGFloat = 6
        #endif

        let items = displayMedia

        return VStack(spacing: 0) {
            LazyVGrid(columns: columns, spacing: gridSpacing) {
                ForEach(items) { mediaItem in
                    MediaGridItem(item: mediaItem) {
                        withAnimation(Motion.fade) {
                            selectedMedia = mediaItem
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 2)

            // Infinite scroll sentinel for media
            if hasMoreNotes && !items.isEmpty {
                Color.clear
                    .frame(height: 1)
                    .onAppear {
                        loadOlderProfileNotes()
                    }
                if isLoadingOlderNotes {
                    ProgressView()
                        .scaleEffect(0.6)
                        .tint(Color.havenPurple)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                }
            }
        }
    }

    @ViewBuilder
    private func mediaViewerContent(for item: MediaItem) -> some View {
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
                    #if os(iOS)
                    if let message = saveToPhotosMessage {
                        Text(message)
                            .font(.appCaption)
                            .foregroundColor(message.contains("Saved") ? .green : .red)
                            .transition(.opacity)
                    }
                    #endif
                }
                .padding()
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
    private var fullScreenOverlay: some View {
        #if os(macOS)
        if let item = selectedMedia {
            mediaViewerContent(for: item)
        }
        #endif
    }

    #if os(iOS)
    private func saveMediaToPhotos(item: MediaItem) {
        saveToPhotosMessage = nil

        Task {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                await MainActor.run {
                    saveToPhotosMessage = "Photo library access denied"
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
                    withAnimation { saveToPhotosMessage = "Saved to Photos" }
                    Task {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        await MainActor.run { withAnimation { saveToPhotosMessage = nil } }
                    }
                }
            } catch {
                await MainActor.run {
                    saveToPhotosMessage = "Failed to save media"
                }
            }
        }
    }
    #endif

    #if os(macOS)
    private func installKeyMonitor() {
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

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }
    #endif

    private func navigateMedia(direction: Int) {
        guard let current = selectedMedia,
              let index = displayMedia.firstIndex(where: { $0.id == current.id }) else { return }
        let newIndex = index + direction
        guard displayMedia.indices.contains(newIndex) else { return }
        withAnimation(Motion.fade) { selectedMedia = displayMedia[newIndex] }
    }

    private var sectionEmptyIcon: String {
        switch selectedSection {
        case .notes: return "text.bubble"
        case .media: return "photo"
        case .replies: return "arrowshape.turn.up.left"
        default: return selectedSection.symbol
        }
    }

    // MARK: - Refresh

    private func refreshProfile() async {
        nostrService.fetchMissingProfiles(for: [pubkey])

        disconnectClients()
        profileNotes.removeAll()
        seenNoteIds.removeAll()
        isLoadingNotes = false
        isLoadingOlderNotes = false
        hasMoreNotes = true
        olderPageSubId = nil
        quietOlderPages = 0
        autoPagedInARow = 0
        taggedNotes.removeAll()
        seenTaggedIds.removeAll()
        isLoadingOlderTaggedNotes = false
        hasMoreTaggedNotes = true
        olderTaggedSubId = nil
        quietOlderTaggedPages = 0
        autoPagedTaggedInARow = 0
        followingCount = nil
        followsMe = false
        followersCount = nil
        followerPubkeys.removeAll()
        totalNoteCount = nil
        totalMediaCount = nil

        fetchAuthorNotes()
        fetchLocalRelayCounts()

        try? await Task.sleep(nanoseconds: 500_000_000)
    }

    // MARK: - Local relay counts (own profile)

    private func fetchLocalRelayCounts() {
        guard isOwnProfile else { return }
        guard RelayProcessManager.shared.isRunning && !RelayProcessManager.shared.isBooting else { return }

        let config = ConfigService.shared.config
        #if os(macOS)
        let baseURLString = "ws://127.0.0.1:\(config.relayPort)"
        #else
        let baseURLString = "wss://127.0.0.1:\(config.relayPort)"
        #endif
        guard let baseURL = URL(string: baseURLString) else { return }

        Task {
            // Fetch kind 1 note count
            let noteCount = await nostrService.fetchCount(
                from: [baseURL],
                filter: ["kinds": [1], "authors": [pubkey]]
            )
            if let count = noteCount, count > 0 {
                await MainActor.run { totalNoteCount = count }
            }

            // Fetch media count via blossom blob list
            let blobs = await StatsService.shared.fetchBlobList(for: pubkey)
            if !blobs.isEmpty {
                await MainActor.run { totalMediaCount = blobs.count }
            }
        }
    }


    // MARK: - Profile editing

    private func applyProfileUpdate(_ updated: FeedProfile) {
        nostrService.profiles[pubkey] = updated
        nostrService.saveProfilesThrottled()
    }

    // MARK: - Note streaming

    private func fetchAuthorNotes() {
        guard !isLoadingNotes else { return }
        isLoadingNotes = true

        let existing = feedService.notes.filter { $0.pubkey == pubkey }
        for note in existing {
            if !seenNoteIds.contains(note.id) {
                seenNoteIds.insert(note.id)
                profileNotes.append(note)
            }
        }
        profileNotes.sort(by: Self.newestFirst)

        var relayURLs: [URL] = []
        if RelayProcessManager.shared.isRunning && !RelayProcessManager.shared.isBooting {
            let config = ConfigService.shared.config
            if let local = URL(string: config.nostrURL) {
                relayURLs.append(local)
            }
        }
        let feedRelays = ConfigService.shared.config.activeFeedRelays
        let externalStrs = feedRelays.isEmpty ? [
            "wss://relay.primal.net",
            "wss://relay.nos.social"
        ] : feedRelays
        // Use up to 3 external relays to improve chances of finding the user's data.
        relayURLs.append(contentsOf: externalStrs.prefix(3).compactMap { URL(string: $0) })

        // NIP-65 outbox model: we're fetching events FROM this user, so query their
        // write/outbox relays (where they actually publish), not their read/inbox
        // relays (where others send things TO them).
        if let userRelays = nostrService.outboxRelays[pubkey] {
            let existingStrings = Set(relayURLs.map { $0.absoluteString })
            for relayStr in userRelays.prefix(3) {
                if !existingStrings.contains(relayStr), let url = URL(string: relayStr) {
                    relayURLs.append(url)
                }
            }
        }

        for url in relayURLs {
            let client = WebSocketClient()
            profileClients.append(client)

            client.messageSubject
                .receive(on: DispatchQueue.main)
                .sink { [self] message in
                    self.handleProfileNoteMessage(message)
                }
                .store(in: &profileCancellables)

            client.$connectionState
                .receive(on: DispatchQueue.main)
                .sink { state in
                    if state == .connected {
                        let notesFilter: [String: Any] = [
                            "kinds": [1, 6, 30023],
                            "authors": [pubkey],
                            "limit": 50
                        ]
                        let profileFilter: [String: Any] = [
                            "kinds": [0],
                            "authors": [pubkey],
                            "limit": 1
                        ]
                        let contactFilter: [String: Any] = [
                            "kinds": [3],
                            "authors": [pubkey],
                            "limit": 1
                        ]
                        let followersFilter: [String: Any] = [
                            "kinds": [3],
                            "#p": [pubkey],
                            "limit": 100
                        ]
                        let taggedFilter: [String: Any] = [
                            "kinds": [1, 6, 30023],
                            "#p": [pubkey],
                            "limit": 50
                        ]
                        let req: [Any] = ["REQ", "profile-\(UUID().uuidString.prefix(6))", notesFilter, profileFilter, contactFilter, followersFilter, taggedFilter]
                        if let data = try? JSONSerialization.data(withJSONObject: req),
                           let str = String(data: data, encoding: .utf8) {
                            client.send(text: str)
                        }
                    }
                }
                .store(in: &profileCancellables)

            client.connect(url: url)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            isLoadingNotes = false
        }
    }

    private func handleProfileNoteMessage(_ message: String) {
        guard let data = message.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let type = json[0] as? String else { return }

        if type == "EVENT", json.count >= 3,
           let eventDict = json[2] as? [String: Any],
           let eventData = try? JSONSerialization.data(withJSONObject: eventDict),
           let event = try? JSONDecoder().decode(NostrEvent.self, from: eventData) {

            // Handle kind 0 (profile metadata) from the target user
            if event.kind == 0, event.pubkey == pubkey {
                if let contentData = event.content.data(using: .utf8),
                   let metadata = try? JSONSerialization.jsonObject(with: contentData) as? [String: Any] {
                    var prof = nostrService.profiles[pubkey] ?? FeedProfile(pubkey: pubkey)
                    prof.name = metadata["name"] as? String
                    prof.displayName = metadata["display_name"] as? String
                    prof.pictureURL = (metadata["picture"] as? String).flatMap { URL(string: $0) }
                    prof.bannerURL = (metadata["banner"] as? String).flatMap { URL(string: $0) }
                    prof.nip05 = metadata["nip05"] as? String
                    prof.about = metadata["about"] as? String
                    prof.lud16 = metadata["lud16"] as? String
                    prof.lud06 = metadata["lud06"] as? String
                    prof.website = metadata["website"] as? String
                    nostrService.profiles[pubkey] = prof
                }
                return
            }

            if event.kind == 3 {
                let pTags = event.tags.filter { $0.count >= 2 && $0[0] == "p" }
                if event.pubkey == pubkey {
                    // This user's own contact list → extract following count and followsMe.
                    // followsMe is true if they follow ANY of our accounts (owner or
                    // whitelisted) so the badge is consistent across account switches.
                    let count = pTags.filter { $0[1] != pubkey }.count
                    self.followingCount = count
                    let ourHexKeys: Set<String> = Set(configService.allAccountNpubs.compactMap { Bech32.decode($0)?.hexString })
                    if !ourHexKeys.isEmpty {
                        self.followsMe = pTags.contains { ourHexKeys.contains($0[1]) }
                    }
                } else {
                    // Someone else's contact list containing this pubkey → they follow this user
                    followerPubkeys.insert(event.pubkey)
                    followersCount = followerPubkeys.count
                }
                return
            }

            // Check if this is a tagged event (authored by someone else, but p-tagging the profile user)
            let isTaggedEvent = event.pubkey != pubkey &&
                [1, 6, 30023].contains(event.kind) &&
                event.tags.contains(where: { $0.count >= 2 && $0[0] == "p" && $0[1] == pubkey })

            if isTaggedEvent {
                guard !seenTaggedIds.contains(event.id) else { return }
                seenTaggedIds.insert(event.id)

                let note = FeedNote(
                    id: event.id,
                    pubkey: event.pubkey,
                    content: event.content,
                    createdAt: Date(timeIntervalSince1970: TimeInterval(event.created_at)),
                    tags: event.tags,
                    kind: event.kind
                )

                taggedNotes.append(note)
                taggedNotes.sort(by: Self.newestFirst)

                // Fetch profile for the tagger
                if nostrService.profiles[event.pubkey] == nil {
                    nostrService.fetchMissingProfiles(for: [event.pubkey])
                }

                // Trigger fetch of the original note for empty-content reposts
                if event.kind == 6 && event.content.isEmpty,
                   let refId = event.tags.first(where: { $0.count >= 2 && $0[0] == "e" })?[1] {
                    feedService.fetchMissingNote(id: refId)
                }

                return
            }

            // For notes (kind 1, 6, 30023), only show from the target user
            guard event.pubkey == pubkey else { return }

            guard !seenNoteIds.contains(event.id) else { return }
            seenNoteIds.insert(event.id)

            let note = FeedNote(
                id: event.id,
                pubkey: event.pubkey,
                content: event.content,
                createdAt: Date(timeIntervalSince1970: TimeInterval(event.created_at)),
                tags: event.tags,
                kind: event.kind
            )

            profileNotes.append(note)
            profileNotes.sort(by: Self.newestFirst)

            // Trigger fetch of the original note for empty-content reposts
            if event.kind == 6 && event.content.isEmpty,
               let refId = event.tags.first(where: { $0.count >= 2 && $0[0] == "e" })?[1] {
                feedService.fetchMissingNote(id: refId)
            }

            if profile == nil {
                nostrService.fetchMissingProfiles(for: [pubkey])
            }
        } else if type == "EOSE" || type == "CLOSED" {
            // CLOSED counts the same as EOSE: the relay is saying it will send
            // nothing more under this subscription. A refusal (sub cap, rate limit)
            // reads identically to an exhausted history from here, and ignoring it
            // left the page hanging on a relay that was never going to answer.
            let subId = (json.count >= 2 ? json[1] as? String : nil) ?? ""
            if subId.hasPrefix("older-tagged-") {
                guard subId == olderTaggedSubId else { return }
                olderTaggedAnswers += 1
                if olderTaggedAnswers >= olderTaggedExpected {
                    finishOlderTaggedPage(token: olderTaggedToken)
                }
            } else if subId.hasPrefix("older-") {
                guard subId == olderPageSubId else { return }
                olderPageAnswers += 1
                if olderPageAnswers >= olderPageExpected {
                    finishOlderPage(token: olderPageToken)
                }
            } else {
                // The opening subscription is deliberately left open — it is also
                // how new posts reach the profile while it is on screen.
                isLoadingNotes = false
            }
        }
    }

    private func loadOlderProfileNotes() {
        guard !isLoadingOlderNotes, hasMoreNotes else { return }
        guard let oldest = profileNotes.last else { return }
        guard !profileClients.isEmpty else { return }
        isLoadingOlderNotes = true

        olderPageToken &+= 1
        let token = olderPageToken
        let subId = "older-\(UUID().uuidString.prefix(6))"
        olderPageSubId = subId
        olderPageAnswers = 0
        olderPageExpected = profileClients.count
        olderPageCountBefore = profileNotes.count
        olderPageVisibleBefore = currentSectionNotes.count
        olderPageSection = selectedSection

        let filter: [String: Any] = [
            "kinds": [1, 6, 30023],
            "authors": [pubkey],
            "until": Int(oldest.createdAt.timeIntervalSince1970),
            "limit": 50
        ]
        // One subscription id for the whole page, so every relay's answer counts
        // toward the same page and the CLOSE below releases all of them.
        let req: [Any] = ["REQ", subId, filter]
        guard let data = try? JSONSerialization.data(withJSONObject: req),
              let str = String(data: data, encoding: .utf8) else {
            isLoadingOlderNotes = false
            return
        }
        for client in profileClients {
            client.send(text: str)
        }

        // Fallback only. Normally the page finishes when every relay has answered.
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            finishOlderPage(token: token)
        }
    }

    private func finishOlderPage(token: Int) {
        guard token == olderPageToken, isLoadingOlderNotes else { return }
        isLoadingOlderNotes = false
        if let subId = olderPageSubId {
            closeProfileSubscription(subId)
            olderPageSubId = nil
        }

        let grew = profileNotes.count > olderPageCountBefore
        let visibleGrew = currentSectionNotes.count > olderPageVisibleBefore

        if grew {
            quietOlderPages = 0
        } else {
            // One quiet round is a slow relay far more often than an exhausted
            // history. Only a second empty round in a row ends paging — the old
            // code latched this off after a single 5s window and never reset it,
            // so one slow relay killed paging for the life of the screen.
            quietOlderPages += 1
            if quietOlderPages >= 2 { hasMoreNotes = false }
        }

        // The scroll sentinel only fires again when the VISIBLE list grows. A page
        // that was entirely replies adds nothing to the Notes tab, so paging would
        // stop with history still left. Carry on ourselves — bounded, so one flick
        // of the scroll cannot walk the whole archive.
        guard hasMoreNotes,
              !visibleGrew,
              olderPageSection == selectedSection,
              autoPagedInARow < 8 else {
            autoPagedInARow = 0
            return
        }
        autoPagedInARow += 1
        loadOlderProfileNotes()
    }

    /// The paging subscriptions are one-shot, but nothing ever released them.
    /// Every page leaked one on every relay, and relays that cap concurrent REQs
    /// start refusing — which this screen then read as "no more notes".
    private func closeProfileSubscription(_ subId: String) {
        let msg: [Any] = ["CLOSE", subId]
        guard let data = try? JSONSerialization.data(withJSONObject: msg),
              let str = String(data: data, encoding: .utf8) else { return }
        for client in profileClients {
            client.send(text: str)
        }
    }

    private func loadOlderTaggedNotes() {
        guard !isLoadingOlderTaggedNotes, hasMoreTaggedNotes else { return }
        guard let oldest = taggedNotes.last else { return }
        guard !profileClients.isEmpty else { return }
        isLoadingOlderTaggedNotes = true

        olderTaggedToken &+= 1
        let token = olderTaggedToken
        let subId = "older-tagged-\(UUID().uuidString.prefix(6))"
        olderTaggedSubId = subId
        olderTaggedAnswers = 0
        olderTaggedExpected = profileClients.count
        olderTaggedCountBefore = taggedNotes.count
        olderTaggedVisibleBefore = taggedFilteredNotes.count

        let filter: [String: Any] = [
            "kinds": [1, 6, 30023],
            "#p": [pubkey],
            "until": Int(oldest.createdAt.timeIntervalSince1970),
            "limit": 50
        ]
        let req: [Any] = ["REQ", subId, filter]
        guard let data = try? JSONSerialization.data(withJSONObject: req),
              let str = String(data: data, encoding: .utf8) else {
            isLoadingOlderTaggedNotes = false
            return
        }
        for client in profileClients {
            client.send(text: str)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            finishOlderTaggedPage(token: token)
        }
    }

    private func finishOlderTaggedPage(token: Int) {
        guard token == olderTaggedToken, isLoadingOlderTaggedNotes else { return }
        isLoadingOlderTaggedNotes = false
        if let subId = olderTaggedSubId {
            closeProfileSubscription(subId)
            olderTaggedSubId = nil
        }

        let grew = taggedNotes.count > olderTaggedCountBefore
        // Tagged hides the profile owner's own notes, so a page can grow the pool
        // without adding a single visible row — same stall as the Notes tab.
        let visibleGrew = taggedFilteredNotes.count > olderTaggedVisibleBefore

        if grew {
            quietOlderTaggedPages = 0
        } else {
            quietOlderTaggedPages += 1
            if quietOlderTaggedPages >= 2 { hasMoreTaggedNotes = false }
        }

        guard hasMoreTaggedNotes,
              !visibleGrew,
              selectedSection == .tagged,
              autoPagedTaggedInARow < 8 else {
            autoPagedTaggedInARow = 0
            return
        }
        autoPagedTaggedInARow += 1
        loadOlderTaggedNotes()
    }

    private func disconnectClients() {
        for client in profileClients {
            client.disconnect()
        }
        profileClients.removeAll()
        profileCancellables.removeAll()
    }

    private func formatSats(_ sats: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        formatter.usesGroupingSeparator = true
        let formatted = formatter.string(from: NSNumber(value: sats)) ?? "\(sats)"
        return "\(formatted) sats"
    }

    private func shortInt(_ n: Int) -> String {
        if n >= 1_000_000 {
            return String(format: "%.1fM", Double(n) / 1_000_000)
        } else if n >= 1_000 {
            return String(format: "%.1fk", Double(n) / 1_000)
        }
        return "\(n)"
    }

    // MARK: - Helpers

    private var shortPubkey: String {
        String(pubkey.prefix(8)) + "…" + String(pubkey.suffix(4))
    }

    private var formattedNpub: String {
        if let data = Bech32.hexToData(pubkey),
           let npub = Bech32.encode(hrp: "npub", data: data) {
            return String(npub.prefix(12)) + "…" + String(npub.suffix(8))
        }
        return "npub…" + String(pubkey.suffix(8))
    }

    private func formattedAddress(_ address: String) -> String {
        guard address.count > 16 else { return address }
        return String(address.prefix(10)) + "…" + String(address.suffix(8))
    }

    private var lightningAddress: String? {
        guard let profile = profile else { return nil }
        if let lud06 = profile.lud06, !lud06.isEmpty { return "lnurl:" + lud06 }
        if let lud16 = profile.lud16, !lud16.isEmpty { return lud16 }
        // NIP-05 resolves to /.well-known/nostr.json — a completely different endpoint
        // from the LUD-16 /.well-known/lnurlp/ path. Do NOT use NIP-05 as a lightning address.
        return nil
    }

    private func copyNpub() {
        if let data = Bech32.hexToData(pubkey),
           let npub = Bech32.encode(hrp: "npub", data: data) {
            copyToClipboard(npub)
            triggerCopied($copiedNpub)
        }
    }

    private func copyToClipboard(_ string: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #else
        UIPasteboard.general.string = string
        #endif
    }

    private func triggerCopied(_ flag: Binding<Bool>) {
        flag.wrappedValue = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            flag.wrappedValue = false
        }
    }

    private func toggleFollow() {
        let name = profile?.bestName ?? shortPubkey
        if isFollowing {
            switch feedService.unfollowUser(pubkey) {
            case .success:
                FollowNotificationManager.shared.add(recipientName: name, kind: .unfollowed)
            case .failure(.contactsNotLoaded), .failure(.listUnavailable):
                // Queued until the follow list is confirmed; not an error.
                FollowNotificationManager.shared.addPending(pubkey: pubkey, recipientName: name, follow: false)
            case .failure(let err):
                FollowNotificationManager.shared.add(recipientName: name, kind: .failed(unfollowErrorMessage(err)))
            }
        } else {
            switch feedService.followUser(pubkey) {
            case .success:
                FollowNotificationManager.shared.add(recipientName: name, kind: .followed)
            case .failure(.contactsNotLoaded), .failure(.listUnavailable):
                FollowNotificationManager.shared.addPending(pubkey: pubkey, recipientName: name, follow: true)
            case .failure(let err):
                FollowNotificationManager.shared.add(recipientName: name, kind: .failed(followErrorMessage(err)))
            }
        }
    }

    private func toggleBlock() {
        guard let data = Data(hex: pubkey),
              let npub = Bech32.encode(hrp: "npub", data: data) else { return }
        if isBlocked {
            configService.unblockProfile(npub)
        } else {
            configService.blockProfile(npub)
        }
    }

    private func toggleThrottle() {
        guard let data = Data(hex: pubkey),
              let npub = Bech32.encode(hrp: "npub", data: data) else { return }
        if isThrottled {
            configService.unthrottleProfile(npub)
        } else {
            // Default to 5 posts visible when throttling
            configService.throttleProfile(npub, maxPosts: 5)
        }
    }

    private func followErrorMessage(_ err: FeedService.FollowActionError) -> String {
        switch err {
        case .contactsNotLoaded, .listUnavailable: return "Following once your follow list loads…"
        case .alreadyFollowing:  return "Already following"
        case .cannotUnfollowSelf: return "Follow failed"
        }
    }

    private func unfollowErrorMessage(_ err: FeedService.FollowActionError) -> String {
        switch err {
        case .contactsNotLoaded, .listUnavailable: return "Unfollowing once your follow list loads…"
        case .cannotUnfollowSelf: return "Can't unfollow yourself"
        case .alreadyFollowing:   return "Unfollow failed"
        }
    }

    private func zapProfile(lud16: String, amount: Int? = nil) async {
        do {
            try await ZapService.shared.zapNote(
                noteId: pubkey,
                notePubkey: pubkey,
                lud16: lud16,
                amountSats: amount
            )
            await MainActor.run {
                showLightning = true
            }
        } catch {
            #if DEBUG
            print("ProfileView: Zap failed: \(error)")
            #endif
        }
    }
}

// MARK: - ProfileEditView

struct ProfileEditView: View {
    @Environment(\.dismiss) private var dismiss
    var onDismiss: (() -> Void)? = nil
    @EnvironmentObject var nostrService: NostrService

    let existing: FeedProfile
    let onSave: (FeedProfile) -> Void

    @State private var displayName: String = ""
    @State private var name: String = ""
    @State private var about: String = ""
    @State private var pictureURL: String = ""
    @State private var nip05: String = ""
    @State private var lud16: String = ""
    @State private var website: String = ""

    @State private var isSaving = false
    @State private var errorMessage: String?
    /// What the form showed when opened, by kind-0 key: a save applies only fields changed from it.
    @State private var initialFields: [String: String] = [:]

    var body: some View {
        platformContainer {
            VStack(spacing: 0) {
                editHeader

                ScrollView {
                    VStack(spacing: 0) {
                        previewBlock

                        divider

                        fieldGroup(title: "IDENTITY") {
                            field(label: "Display Name", text: $displayName, placeholder: "Satoshi Nakamoto")
                            fieldDivider
                            field(label: "Username", text: $name, placeholder: "satoshi")
                            fieldDivider
                            field(label: "NIP-05", text: $nip05, placeholder: "you@domain.com", keyboardKind: .emailLike)
                        }

                        divider

                        fieldGroup(title: "BIO") {
                            multilineField(label: "About", text: $about, placeholder: "Tell people about yourself…")
                        }

                        divider

                        fieldGroup(title: "MEDIA") {
                            field(label: "Picture URL", text: $pictureURL, placeholder: "https://…", keyboardKind: .urlLike)
                            fieldDivider
                            field(label: "Website", text: $website, placeholder: "yourdomain.com", keyboardKind: .urlLike)
                        }

                        divider

                        fieldGroup(title: "LIGHTNING") {
                            field(label: "Address (lud16)", text: $lud16, placeholder: "you@walletofsatoshi.com", keyboardKind: .emailLike)
                        }

                        if let err = errorMessage {
                            Text(err)
                                .font(.appSystem(size: 12))
                                .foregroundColor(.red)
                                .padding(.horizontal, 16)
                                .padding(.top, 16)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        Spacer(minLength: 32)
                    }
                }
            }
        }
        .onAppear { loadFromExisting() }
    }

    @ViewBuilder
    private func platformContainer<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        #if os(macOS)
        content()
            .frame(minWidth: 480, minHeight: 600)
            .background(Color.platformWindowBackground)
        #else
        content()
            .background(Color.platformWindowBackground.ignoresSafeArea())
        #endif
    }

    private var editHeader: some View {
        HStack {
            Button("Cancel") { performDismiss() }
                .foregroundColor(.secondary)
                .keyboardShortcut(.cancelAction)

            Spacer()

            Text("Edit Profile")
                .font(.appSystem(size: 15, weight: .semibold))

            Spacer()

            Button(action: save) {
                if isSaving {
                    ProgressView()
                        .scaleEffect(0.7)
                        .tint(Color.havenPurple)
                } else {
                    Text("Save")
                        .font(.appSystem(size: 13, weight: .semibold))
                        .foregroundColor(.havenPurple)
                }
            }
            .disabled(isSaving)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.platformControlBackground)
        .overlay(
            Rectangle()
                .fill(Color.platformSeparator.opacity(0.5))
                .frame(height: 0.5),
            alignment: .bottom
        )
    }

    private var previewBlock: some View {
        HStack(spacing: 14) {
            AvatarView(url: URL(string: pictureURL), pubkey: existing.pubkey, size: 56)
                .overlay(Circle().stroke(Color.havenPurple.opacity(0.35), lineWidth: 1.5))

            VStack(alignment: .leading, spacing: 3) {
                Text(displayName.isEmpty ? (name.isEmpty ? "Unnamed" : name) : displayName)
                    .font(.appSystem(size: 17, weight: .bold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                if !nip05.isEmpty {
                    Text(nip05)
                        .font(.appSystem(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                if !about.isEmpty {
                    Text(about)
                        .font(.appSystem(size: 12))
                        .foregroundColor(.primary.opacity(0.75))
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.platformSeparator.opacity(0.5))
            .frame(height: 0.5)
            .padding(.vertical, 8)
    }

    private var fieldDivider: some View {
        Rectangle()
            .fill(Color.platformSeparator.opacity(0.4))
            .frame(height: 0.5)
            .padding(.leading, 16)
    }

    private func fieldGroup<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.appSystem(size: 10, weight: .heavy))
                .tracking(0.7)
                .foregroundColor(.secondary)
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
            content()
        }
    }

    enum KeyboardKind { case `default`, urlLike, emailLike }

    @ViewBuilder
    private func field(label: String, text: Binding<String>, placeholder: String, keyboardKind: KeyboardKind = .default) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.appSystem(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 100, alignment: .leading)

            TextField(placeholder, text: text)
                .font(.appSystem(size: 13))
                .textFieldStyle(.plain)
                .modifier(KeyboardModifier(kind: keyboardKind))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func multilineField(label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.appSystem(size: 11, weight: .semibold))
                .foregroundColor(.secondary)

            ZStack(alignment: .topLeading) {
                if text.wrappedValue.isEmpty {
                    Text(placeholder)
                        .font(.appSystem(size: 13))
                        .foregroundColor(.secondary.opacity(0.6))
                        .padding(.top, 8)
                        .padding(.leading, 6)
                }
                #if os(iOS)
                TextEditor(text: text)
                    .font(.appSystem(size: 13))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 90)
                #else
                TextEditor(text: text)
                    .font(.appSystem(size: 13))
                    .frame(minHeight: 90)
                #endif
            }
            .padding(6)
            .background(Color.secondary.opacity(0.08))
            .cornerRadius(6)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func loadFromExisting() {
        displayName = existing.displayName ?? ""
        name = existing.name ?? ""
        about = existing.about ?? ""
        pictureURL = existing.pictureURL?.absoluteString ?? ""
        nip05 = existing.nip05 ?? ""
        lud16 = existing.lud16 ?? ""
        website = existing.website ?? ""
        initialFields = formFields()
    }

    private func formFields() -> [String: String] {
        [
            ProfileMetadataMerge.displayName: displayName,
            ProfileMetadataMerge.name: name,
            ProfileMetadataMerge.about: about,
            ProfileMetadataMerge.picture: pictureURL,
            ProfileMetadataMerge.nip05: nip05,
            ProfileMetadataMerge.lud16: lud16,
            ProfileMetadataMerge.website: website,
        ]
    }

    private func save() {
        errorMessage = nil
        isSaving = true
        let edited = formFields()
        let initial = initialFields

        Task {
            // A kind 0 replaces the whole profile. Start from the newest one on
            // the relays so banner, lud06 and every key this form doesn't show
            // survive; if it can't be fetched, publishing would wipe them, so
            // don't (same rule as the follow list).
            let pubkey = nostrService.activeHexPubkey
            let alsoAsk = (nostrService.outboxRelays[pubkey] ?? []) + (nostrService.relayLists[pubkey] ?? [])
            let lookup = await nostrService.lookupNewestReplaceable(kind: 0, for: pubkey, alsoAsk: alsoAsk)
            guard lookup.event != nil || lookup.confirmedNone else {
                errorMessage = "Couldn't load your current profile from the relays. Nothing was changed; try again."
                isSaving = false
                return
            }
            let merged = ProfileMetadataMerge.merge(base: ProfileMetadataMerge.parseContent(lookup.event?.content),
                                                    initial: initial, edited: edited)
            guard let jsonStr = ProfileMetadataMerge.encode(merged) else {
                errorMessage = "Could not encode profile."
                isSaving = false
                return
            }

            guard let signed = await nostrService.signEventAsync(kind: 0, content: jsonStr, tags: []) else {
                errorMessage = "Could not sign event. Check that your key is available."
                isSaving = false
                return
            }

            nostrService.postEvent(signed)

            var updated = existing
            updated.name = merged[ProfileMetadataMerge.name] as? String
            updated.displayName = merged[ProfileMetadataMerge.displayName] as? String
            updated.about = merged[ProfileMetadataMerge.about] as? String
            updated.pictureURL = (merged[ProfileMetadataMerge.picture] as? String).flatMap { URL(string: $0) }
            updated.bannerURL = (merged["banner"] as? String).flatMap { URL(string: $0) }
            updated.nip05 = merged[ProfileMetadataMerge.nip05] as? String
            updated.lud16 = merged[ProfileMetadataMerge.lud16] as? String
            updated.lud06 = merged["lud06"] as? String
            updated.website = merged[ProfileMetadataMerge.website] as? String

            onSave(updated)

            isSaving = false
            performDismiss()
        }
    }

    private func performDismiss() {
        if let onDismiss = onDismiss {
            onDismiss()
        } else {
            dismiss()
        }
    }
}

private struct KeyboardModifier: ViewModifier {
    let kind: ProfileEditView.KeyboardKind

    func body(content: Content) -> some View {
        #if os(iOS)
        switch kind {
        case .urlLike:
            content
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .autocorrectionDisabled(true)
        case .emailLike:
            content
                .textInputAutocapitalization(.never)
                .keyboardType(.emailAddress)
                .autocorrectionDisabled(true)
        case .default:
            content
        }
        #else
        content
        #endif
    }
}

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
    private var loadedPubkey: String?

    func load(pubkey: String, relays: [URL]) {
        guard loadedPubkey != pubkey else { return }
        loadedPubkey = pubkey
        articles = []; reels = []; tracks = []
        Task { await loadEvents(pubkey: pubkey, relays: relays) }
        Task { await loadMusic(pubkey: pubkey) }
    }

    private func loadEvents(pubkey: String, relays: [URL]) async {
        let filters: [[String: Any]] = [
            ["kinds": [30023], "authors": [pubkey], "limit": 100],
            ["kinds": ReelsFeedService.videoKinds, "authors": [pubkey], "limit": 100],
        ]
        let events = await ZapHistoryService.query(filters: filters, relays: relays, timeout: 8)
        guard loadedPubkey == pubkey else { return }
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

// MARK: - Profile banner

/// The strip across the top of a profile. Runs edge to edge and up under the
/// navigation bar, stretches when pulled down, and fades into the page at the
/// bottom. Until the banner arrives, or when there is none, a wash tinted from
/// the profile picture stands in so the header never jumps or sits empty.
private struct ProfileBannerView: View {
    let bannerURL: URL?
    let avatarURL: URL?
    let pubkey: String
    let height: CGFloat
    let topInset: CGFloat
    let onTap: (URL) -> Void

    @State private var image: PlatformImage?
    @State private var tint: Color?

    var body: some View {
        GeometryReader { geo in
            // Up under the navigation bar at rest, and further as the page is
            // pulled down, so the stretch never shows a gap.
            let reach = topInset + max(0, geo.frame(in: .scrollView(axis: .vertical)).minY)
            ZStack {
                wash
                if let image {
                    Image(platformImage: image)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                }
            }
            .frame(width: geo.size.width, height: height + reach)
            .clipped()
            .overlay(alignment: .top) {
                // Keeps the toolbar buttons and close button legible on a
                // bright banner.
                LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: min(reach + 56, height + reach))
            }
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [.clear, Color.platformWindowBackground], startPoint: .top, endPoint: .bottom)
                    .frame(height: height * 0.45)
            }
            .offset(y: -reach)
        }
        .frame(height: height)
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
        guard let data = MediaCacheService.shared.loadFromCache(url: url),
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

private extension View {
    @ViewBuilder
    func hiddenTopScrollEdge() -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            self.scrollEdgeEffectHidden(true, for: .top)
        } else {
            self
        }
    }
}
