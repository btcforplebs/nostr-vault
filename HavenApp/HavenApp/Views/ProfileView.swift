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
    /// Not observed: the main feed changes many times a second while it
    /// loads, and observing all of it redrew this page each time.
    /// `feedWatch` redraws only for the parts this page shows.
    private var feedService: FeedService { .shared }
    @StateObject private var feedWatch = ProfileFeedWatch()
    @StateObject private var dmService = DMService.shared
    /// Likes, reposts, replies and zap sats under each post.
    @ObservedObject private var engagementStore = ProfileEngagementStore.shared
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
    /// This profile's follows, in contact-list order (other profiles only;
    /// your own come from the feed's follow list).
    @State private var followingList: [String] = []
    /// Follower → created_at of their list naming this profile.
    @State private var followerSeenAt: [String: Int64] = [:]
    /// The Following / Followers page, open on the tab that was tapped.
    @State private var followListTab: FollowListTab?
    /// The viewer's follower ledger, read when the page opens.
    @State private var viewerLedger: FollowerSnapshot?
    /// Older followers, a page at a time, as the Followers list scrolls.
    @State private var followerPageSubId: String?
    @State private var followerPageToken = 0
    @State private var followerPageAnswers = 0
    @State private var followerPageExpected = 0
    @State private var followerPageCountBefore = 0
    @State private var quietFollowerPages = 0
    @State private var followersExhausted = false
    /// Finished follower pages; the list's loader is keyed on it so it asks
    /// again after a page that brought nobody new.
    @State private var followerPagesDone = 0
    /// created_at of the kind 0 and kind 3 now shown. Each relay answers with
    /// its own copy and the answers arrive in any order, so an older copy from
    /// a slow relay must not replace a newer one already on screen.
    @State private var shownMetadataAt: Int64 = 0
    @State private var shownContactsAt: Int64 = 0
    /// Largest NIP-45 COUNT any relay gave for this profile's followers.
    @State private var relayFollowerCount: Int? = nil

    // Note streaming
    @State private var profileNotes: [FeedNote] = []
    @State private var isLoadingNotes = false
    /// Bumped by each opening load, so the fallback timer of an earlier load
    /// cannot end a later one early.
    @State private var notesLoadToken = 0
    /// False until the first load starts, so the first frame reads
    /// "Loading…" rather than "No notes yet".
    @State private var notesLoadStarted = false
    /// Relays of the opening load that have not answered yet (EOSE, CLOSED or
    /// a failed connection). Loading ends when the last one answers, not the
    /// first: the phone's own relay always answers first, and for someone
    /// else it usually has nothing.
    @State private var openingPending = Set<Int>()
    /// Notes received but not yet on screen. They go in together a moment
    /// later, in one sort and one redraw, instead of one of each per event.
    @State private var pending = PendingProfileNotes()
    /// The lists the tabs and counts read, worked out once per change to the
    /// notes rather than many times on every redraw.
    @State private var buckets = ProfileNoteBuckets()
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

    @State private var selectedSection: ProfileSection = .notes
    /// The late tabs on show. Set only when their loader finishes, so the
    /// tab bar re-spaces once instead of once per tab as each one arrives.
    @State private var revealedSections = Set<ProfileSection>()
    /// Set once the profile has waited long enough for its metadata; the
    /// header stops holding space for a bio that is not coming.
    @State private var metadataWaitOver = false

    /// Height of the profile's scroll view. A section is at least this tall,

    /// so picking one with a single item keeps the tabs where they were and

    /// leaves blank space below, instead of the page snapping back down.

    @State private var viewportHeight: CGFloat = 0
    /// Width of the scroll view; the banner's height follows it.
    @State private var viewportWidth: CGFloat = 0
    /// Height of the bars above the scroll view's content, which the banner
    /// reaches up under.
    @State private var topInset: CGFloat = 0
    /// The topmost note on screen, which the scroll view keeps in place.
    @State private var scrolledNoteID: String?
    @StateObject private var shop = SellerListingsLoader()
    /// This person's articles, diVines and music, each a tab when they have any.
    @StateObject private var extras = ProfileExtrasLoader()
    @State private var showingArticle: ArticleRoute?
    @State private var musicSheet: MusicSheet?
    @State private var showingSell = false
    @State private var selectedListing: MarketListing?

    /// The four tabs every profile has come first; the ones that only show
    /// once this person's articles, diVines, music or listings arrive go
    /// after them, so a late tab never pushes an earlier one along.
    enum ProfileSection: String, CaseIterable, Identifiable {
        case notes = "Notes"
        case media = "Media"
        case replies = "Replies"
        case tagged = "Tagged"
        case articles = "Articles"
        case divines = "diVines"
        case music = "Music"
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

    private var topNotes: [FeedNote] { buckets.top }
    private var mediaNotes: [FeedNote] { buckets.media }
    private var replyNotes: [FeedNote] { buckets.replies }
    private var taggedFilteredNotes: [FeedNote] { buckets.tagged }

    /// Splits the notes into the tab lists. `mediaURLs` scans each note's
    /// text, so this runs when the notes change, never from `body`.
    private func rebucket() {
        var top: [FeedNote] = [], media: [FeedNote] = [], replies: [FeedNote] = []
        for note in profileNotes {
            if note.isReply {
                replies.append(note)
            } else {
                top.append(note)
                if !note.mediaURLs.isEmpty { media.append(note) }
            }
        }
        buckets = ProfileNoteBuckets(
            top: top,
            media: media,
            replies: replies,
            tagged: taggedNotes.filter { $0.pubkey != pubkey }
        )
    }

    private func scheduleFlush() {
        guard !pending.scheduled else { return }
        pending.scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { flushPendingNotes() }
    }

    /// Puts the waiting notes on screen. Anything that reads the lists to
    /// decide something (paging, end of loading) flushes first.
    private func flushPendingNotes() {
        pending.scheduled = false
        guard !pending.notes.isEmpty || !pending.tagged.isEmpty else { return }
        if !pending.notes.isEmpty {
            profileNotes.append(contentsOf: pending.notes)
            profileNotes.sort(by: Self.newestFirst)
            pending.notes.removeAll()
        }
        if !pending.tagged.isEmpty {
            taggedNotes.append(contentsOf: pending.tagged)
            taggedNotes.sort(by: Self.newestFirst)
            pending.tagged.removeAll()
        }
        rebucket()
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

    /// What each tab holds so far. These are the notes loaded, not totals:
    /// `hasMore` says when older pages may still add to them. Your own
    /// relay's note count included replies and your Blossom file count
    /// included every upload, so neither matched its tab and both are gone.
    private var sectionCount: (notes: Int, media: Int, replies: Int, tagged: Int) {
        (topNotes.count, mediaNotes.count, replyNotes.count, taggedFilteredNotes.count)
    }

    /// True until paging has found no older notes. A short profile shows the
    /// sentinel at once, so it pages to the end and drops the "+" quickly.
    private func hasMore(for section: ProfileSection) -> Bool {
        switch section {
        case .notes, .media, .replies: return hasMoreNotes
        case .tagged: return hasMoreTaggedNotes
        default: return false
        }
    }

    /// "48", or "48+" while older pages may still raise it. Nothing loaded
    /// yet with more to come reads "—", as FOLLOWING does before it knows.
    private func countText(for section: ProfileSection) -> String {
        let n = count(for: section)
        guard hasMore(for: section) else { return shortInt(n) }
        return n == 0 ? "—" : shortInt(n) + "+"
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
                    } else if awaitingMetadata {
                        bioPlaceholder
                    }
                    divider
                    statsBlock
                    divider
                    if awaitingMetadata {
                        identityPlaceholder
                    } else {
                        identityBlock
                    }
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
        // Holds the note you are reading in place while notes arrive from
        // each relay and are sorted in above it, and while rows above it
        // grow as their media loads. The main feed does the same.
        .scrollPosition(id: $scrolledNoteID)
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
                // Its own task: SwiftUI cancels the refresh task when this
                // page redraws mid-refresh, which cut every wait inside short
                // and dropped the spinner at once. Awaiting a separate task
                // holds the pull open until the load is actually done.
                await Task { await refreshProfile() }.value
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.platformWindowBackground.ignoresSafeArea())
        .onAppear {
            nostrService.fetchMissingProfiles(for: [pubkey])
            fetchAuthorNotes()
            fetchFollowerCount()
            shop.load(pubkey: pubkey)
            extras.load(pubkey: pubkey, relays: extrasRelays)
            revealLateSections()
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { metadataWaitOver = true }
            #if os(macOS)
            installKeyMonitor()
            #endif
        }
        .onChange(of: extras.isLoading) { _, _ in revealLateSections() }
        .onChange(of: shop.isLoading) { _, _ in revealLateSections() }
        .onChange(of: shop.listings.isEmpty) { _, _ in revealLateSections() }
        .onDisappear {
            // Loads in flight die with their connections; without this a
            // return before the first EOSE skips the notes load entirely.
            disconnectClients()
            isLoadingNotes = false
            openingPending.removeAll()
            isLoadingOlderNotes = false
            olderPageSubId = nil
            isLoadingOlderTaggedNotes = false
            olderTaggedSubId = nil
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
        .modifier(FollowListHost(item: $followListTab) { tab in
            followListPage(startOn: tab)
        })
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

    /// A strip a third as tall as it is wide, the same with or without a
    /// banner (a tinted wash stands in), so nothing below it moves when the
    /// profile or its banner arrives.
    private var bannerHeight: CGFloat {
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
                } else if awaitingMetadata {
                    Text("name@example.com")
                        .font(.appSystem(size: 12))
                        .foregroundColor(.secondary)
                        .redacted(reason: .placeholder)
                        .accessibilityHidden(true)
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

    // MARK: - Metadata placeholders

    /// No kind 0 for this person yet. The header holds the space the NIP-05
    /// line, a short bio and the Lightning row usually take, so the tabs and
    /// notes are not pushed down when they arrive.
    private var awaitingMetadata: Bool {
        guard !metadataWaitOver else { return false }
        guard let p = profile else { return true }
        return p.name == nil && p.displayName == nil && p.about == nil
            && p.pictureURL == nil && p.nip05 == nil && p.lud16 == nil
    }

    private var bioPlaceholder: some View {
        Text("A short bio about this person, about as long as most are, two lines.")
            .font(.appSystem(size: 13))
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .redacted(reason: .placeholder)
            .accessibilityHidden(true)
    }

    private var identityPlaceholder: some View {
        identityRowContent(
            label: "LIGHTNING",
            value: "name@wallet.example",
            icon: "bolt.fill",
            tint: .secondary,
            copied: false,
            trailing: AnyView(EmptyView())
        )
        .redacted(reason: .placeholder)
        .accessibilityHidden(true)
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
            statCell(value: countText(for: .notes), label: "NOTES")
            statDivider
            statCell(value: countText(for: .media), label: "MEDIA")
            statDivider
            Button { openFollowList(.following) } label: {
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
                }
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            statDivider
            Button { openFollowList(.followers) } label: {
                statCell(
                    value: displayedFollowersCount.map(shortInt) ?? "—",
                    label: "FOLLOWERS"
                )
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Follow lists

    private func openFollowList(_ tab: FollowListTab) {
        let viewer = configService.activeAccountHexPubkey
        followListTab = tab
        Task.detached(priority: .userInitiated) {
            let ledger = FollowerSnapshot.load(owner: viewer)
            await MainActor.run { viewerLedger = ledger }
        }
    }

    private func followListPage(startOn tab: FollowListTab) -> some View {
        let ledger = viewerLedger
        let viewerFollowers = ledger.map { Set($0.current.map(\.pubkey)) } ?? []
        let spam = ledger.map { Set($0.followers.filter(\.isSpam).map(\.pubkey)) } ?? []
        let following = isOwnProfile
            ? feedService.followedPubkeys.filter { $0 != pubkey }
            : followingList
        // Your own followers come from the relay's ledger, which is complete.
        // Anyone else's are what relays returned, which may be short.
        let ownLedger = isOwnProfile ? ledger : nil
        let followers: [String: Int64] = ownLedger.map { snap in
            Dictionary(snap.current.map { ($0.pubkey, $0.existing ? $0.listAt : $0.followedAt) }, uniquingKeysWith: max)
        } ?? followerSeenAt
        let haveMore = ownLedger == nil && !followersExhausted && (displayedFollowersCount ?? 0) > followers.count
        return FollowListView(
            subject: pubkey,
            subjectName: profile?.bestName ?? shortPubkey,
            startOn: tab,
            following: following,
            followers: followers,
            followersHaveMore: haveMore,
            followerPagesDone: followerPagesDone,
            followersTotal: ownLedger == nil ? displayedFollowersCount : nil,
            isViewersOwnFollowers: ownLedger != nil,
            followsViewer: viewerFollowers,
            hidden: spam,
            onLoadMoreFollowers: ownLedger == nil ? { loadMoreFollowers() } : nil
        )
        .environmentObject(nostrService)
        .environmentObject(configService)
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
                    withTransaction(instant) {
                        // The other section's notes are not this one's: an
                        // anchor left over would pull the page to it.
                        scrolledNoteID = nil
                        selectedSection = section
                    }
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
            case .shop: return isOwnProfile || revealedSections.contains(.shop)
            // Only when this person has some, so most profiles keep four tabs.
            case .articles, .divines, .music: return revealedSections.contains(section)
            default: return true
            }
        }
    }

    /// Shows the late tabs that have content, all at once. Runs when a
    /// loader finishes; a tab already on show stays while a refresh runs.
    private func revealLateSections() {
        var next = revealedSections
        if !extras.isLoading {
            next.subtract([.articles, .divines, .music])
            if !extras.articles.isEmpty { next.insert(.articles) }
            if !extras.reels.isEmpty { next.insert(.divines) }
            if !extras.tracks.isEmpty { next.insert(.music) }
        }
        if !shop.isLoading {
            if shop.listings.isEmpty { next.remove(.shop) } else { next.insert(.shop) }
        }
        guard next != revealedSections else { return }
        revealedSections = next
        if !visibleSections.contains(selectedSection) { selectedSection = .notes }
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
        count(for: section) > 0 ? countText(for: section) : ""
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
                Text(isLoadingNotes || !notesLoadStarted ? "Loading…" : "No \(selectedSection.rawValue.lowercased()) yet")
                    .font(.appSystem(size: 12))
                    .foregroundColor(.secondary)
                if isLoadingNotes || !notesLoadStarted {
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
                        ).with(engagement: engagementStore.engagement(for: feedService.originalNote(for: note).id)),
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
                        onProfile: { tapped in
                            // This page already shows that profile.
                            guard tapped != pubkey else { return }
                            showingProfileKey = IdentifiableString(id: tapped)
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
            // Numbers under each post, fetched as the posts appear. The tagged
            // tab is other people's posts, so it is left out.
            .task(id: selectedSection == .tagged ? [] : notes.map(\.id)) {
                guard selectedSection != .tagged else { return }
                await engagementStore.load(ids: notes.map { feedService.originalNote(for: $0).id }, author: pubkey)
            }
            .scrollTargetLayout()
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

    /// Pull to refresh. Reloads in place: everything on screen stays until
    /// something newer replaces it, so the page never blanks and refills. New
    /// posts are added at the top, counts change only when a new number
    /// arrives, and the header, Shop and the extra tabs are fetched again.
    /// The spinner stays until every relay has answered the new load.
    private func refreshProfile() async {
        let started = Date()
        nostrService.fetchMissingProfiles(for: [pubkey], force: true)
        shop.load(pubkey: pubkey, force: true)
        extras.load(pubkey: pubkey, relays: extrasRelays, force: true)

        // A page of older notes in flight dies with its connection; let the
        // next scroll to the bottom ask again.
        disconnectClients()
        isLoadingNotes = false
        isLoadingOlderNotes = false
        olderPageSubId = nil
        isLoadingOlderTaggedNotes = false
        olderTaggedSubId = nil

        fetchAuthorNotes()
        fetchFollowerCount()

        // Until every relay has answered (EOSE, CLOSED or a failed
        // connection), 8s at most, and long enough that the spinner reads as
        // having done something.
        while isLoadingNotes, Date().timeIntervalSince(started) < 8 {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let shown = Date().timeIntervalSince(started)
        if shown < 0.6 {
            try? await Task.sleep(nanoseconds: UInt64((0.6 - shown) * 1_000_000_000))
        }
    }

    // MARK: - Follower count

    /// The streamed kind-3 events stop at 100 per relay, so they undercount
    /// anyone with more followers. Relays that answer NIP-45 COUNT give the
    /// full number; show whichever is larger.
    private var displayedFollowersCount: Int? {
        switch (relayFollowerCount, followersCount) {
        case let (relay?, streamed?): return max(relay, streamed)
        case let (relay, streamed): return relay ?? streamed
        }
    }

    /// Asks each relay for its own follower COUNT and keeps the largest.
    /// Relays hold different subsets of contact lists, so adding their
    /// counts together would double-count; the largest single answer is
    /// the closest to the real number.
    private func fetchFollowerCount() {
        var urls: [URL] = []
        var seen = Set<String>()
        // damus and primal answer COUNT; most other popular relays reject it.
        let candidates = ["wss://relay.damus.io", "wss://relay.primal.net"]
            + ConfigService.shared.config.activeFeedRelays.prefix(3)
        for str in candidates where seen.insert(str).inserted {
            if let url = URL(string: str) { urls.append(url) }
        }
        let filter: [String: Any] = ["kinds": [3], "#p": [pubkey]]

        for url in urls {
            Task {
                guard let count = await nostrService.fetchCount(from: [url], filter: filter) else { return }
                await MainActor.run {
                    relayFollowerCount = max(relayFollowerCount ?? 0, count)
                }
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
        notesLoadStarted = true

        let existing = feedService.notes.filter { $0.pubkey == pubkey }
        for note in existing {
            if !seenNoteIds.contains(note.id) {
                seenNoteIds.insert(note.id)
                pending.notes.append(note)
            }
        }
        flushPendingNotes()

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

        openingPending = Set(relayURLs.indices)
        for (relay, url) in relayURLs.enumerated() {
            let client = WebSocketClient()
            profileClients.append(client)

            client.messageSubject
                .receive(on: DispatchQueue.main)
                .sink { [self] message in
                    self.handleProfileNoteMessage(message, relay: relay)
                }
                .store(in: &profileCancellables)

            client.$connectionState
                .receive(on: DispatchQueue.main)
                .sink { state in
                    // A relay that can't be reached has answered too: it
                    // will send nothing.
                    if state == .error { openingRelayAnswered(relay) }
                    if state == .connected {
                        let notesFilter: [String: Any] = [
                            "kinds": [1, 6, 30023, NIP88Poll.kind],
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
                            "kinds": [1, 6, 30023, NIP88Poll.kind],
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

        notesLoadToken += 1
        let token = notesLoadToken
        if relayURLs.isEmpty { isLoadingNotes = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            guard token == notesLoadToken else { return }
            flushPendingNotes()
            openingPending.removeAll()
            isLoadingNotes = false
        }
    }

    private func openingRelayAnswered(_ relay: Int) {
        guard openingPending.remove(relay) != nil else { return }
        if openingPending.isEmpty {
            flushPendingNotes()
            isLoadingNotes = false
        }
    }

    private func handleProfileNoteMessage(_ message: String, relay: Int) {
        guard let data = message.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let type = json[0] as? String else { return }

        if type == "EVENT", json.count >= 3,
           let eventDict = json[2] as? [String: Any],
           let eventData = try? JSONSerialization.data(withJSONObject: eventDict),
           let event = try? JSONDecoder().decode(NostrEvent.self, from: eventData) {

            // Handle kind 0 (profile metadata) from the target user
            if event.kind == 0, event.pubkey == pubkey {
                guard event.created_at >= shownMetadataAt else { return }
                shownMetadataAt = event.created_at
                if let result = ProfileRepository.parseMetadataContent(
                    event.content, pubkey: pubkey,
                    existingProfile: nostrService.profiles[pubkey],
                    createdAt: event.created_at
                ), result.changed {
                    nostrService.profiles[pubkey] = result.profile
                }
                return
            }

            if event.kind == 3 {
                let pTags = event.tags.filter { $0.count >= 2 && $0[0] == "p" }
                if event.pubkey == pubkey {
                    guard event.created_at >= shownContactsAt else { return }
                    shownContactsAt = event.created_at
                    // This user's own contact list → extract following count and followsMe.
                    // followsMe is true if they follow ANY of our accounts (owner or
                    // whitelisted) so the badge is consistent across account switches.
                    var seenTags = Set<String>()
                    let list = pTags.map { $0[1] }.filter { $0 != pubkey && seenTags.insert($0).inserted }
                    self.followingList = list
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
                    followerSeenAt[event.pubkey] = max(followerSeenAt[event.pubkey] ?? 0, event.created_at)
                }
                return
            }

            // Check if this is a tagged event (authored by someone else, but p-tagging the profile user)
            let isTaggedEvent = event.pubkey != pubkey &&
                [1, 6, 30023, NIP88Poll.kind].contains(event.kind) &&
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

                pending.tagged.append(note)
                scheduleFlush()

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

            pending.notes.append(note)
            scheduleFlush()

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
            // Page bookkeeping counts the lists, so they must be complete.
            flushPendingNotes()
            if subId.hasPrefix("followers-page-") {
                guard subId == followerPageSubId else { return }
                followerPageAnswers += 1
                if followerPageAnswers >= followerPageExpected {
                    finishFollowerPage(token: followerPageToken)
                }
            } else if subId.hasPrefix("older-tagged-") {
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
                openingRelayAnswered(relay)
            }
        }
    }

    /// Asks every relay for the next 100 lists naming this profile, older
    /// than the oldest already seen.
    private func loadMoreFollowers() {
        guard followerPageSubId == nil, !followersExhausted, !profileClients.isEmpty,
              let oldest = followerSeenAt.values.min() else { return }
        followerPageToken &+= 1
        let token = followerPageToken
        let subId = "followers-page-\(UUID().uuidString.prefix(6))"
        followerPageSubId = subId
        followerPageAnswers = 0
        followerPageExpected = profileClients.count
        followerPageCountBefore = followerSeenAt.count
        let filter: [String: Any] = ["kinds": [3], "#p": [pubkey], "until": Int(oldest) - 1, "limit": 100]
        guard let data = try? JSONSerialization.data(withJSONObject: ["REQ", subId, filter] as [Any]),
              let str = String(data: data, encoding: .utf8) else {
            followerPageSubId = nil
            return
        }
        for client in profileClients { client.send(text: str) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { finishFollowerPage(token: token) }
    }

    private func finishFollowerPage(token: Int) {
        guard token == followerPageToken, let subId = followerPageSubId else { return }
        closeProfileSubscription(subId)
        followerPageSubId = nil
        if followerSeenAt.count > followerPageCountBefore {
            quietFollowerPages = 0
        } else {
            // Two empty rounds in a row, not one: a single quiet round is more
            // often a slow relay than the end of the list.
            quietFollowerPages += 1
            if quietFollowerPages >= 2 { followersExhausted = true }
        }
        followerPagesDone += 1
    }

    private func loadOlderProfileNotes() {
        guard !isLoadingOlderNotes, hasMoreNotes else { return }
        flushPendingNotes()
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
            "kinds": [1, 6, 30023, NIP88Poll.kind],
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
        flushPendingNotes()
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
        flushPendingNotes()
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
            "kinds": [1, 6, 30023, NIP88Poll.kind],
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
        flushPendingNotes()
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
    @State private var bannerURL: String = ""
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
                        bannerBlock

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
                            field(label: "Banner URL", text: $bannerURL, placeholder: "https://…", keyboardKind: .urlLike)
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

    /// The Banner URL, previewed at the 3:1 shape profiles draw it in.
    /// Hidden until the field holds a URL.
    @ViewBuilder
    private var bannerBlock: some View {
        if let url = URL(string: bannerURL.trimmingCharacters(in: .whitespaces)), url.scheme != nil {
            // The image sits in an overlay so a wide photo can't widen the row.
            Rectangle()
                .fill(Color.havenPurple.opacity(0.12))
                .aspectRatio(3, contentMode: .fit)
                .overlay {
                    CachedAsyncImage(url: url) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        ProgressView().tint(.havenPurple)
                    }
                }
                .clipped()
                .accessibilityLabel("Banner preview")
        }
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
        bannerURL = existing.bannerURL?.absoluteString ?? ""
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
            ProfileMetadataMerge.banner: bannerURL,
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
            // the relays so lud06 and every key this form doesn't show
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
            updated.bannerURL = (merged[ProfileMetadataMerge.banner] as? String).flatMap { URL(string: $0) }
            updated.nip05 = merged[ProfileMetadataMerge.nip05] as? String
            updated.lud16 = merged[ProfileMetadataMerge.lud16] as? String
            updated.lud06 = merged["lud06"] as? String
            updated.website = merged[ProfileMetadataMerge.website] as? String
            updated.metadataCreatedAt = signed.created_at

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

/// Notes received by the profile's stream and waiting to go on screen. A
/// reference, so adding to it does not redraw the page.
private final class PendingProfileNotes {
    var notes: [FeedNote] = []
    var tagged: [FeedNote] = []
    var scheduled = false
}

/// The profile's notes split by tab.
private struct ProfileNoteBuckets {
    var top: [FeedNote] = []
    var media: [FeedNote] = []
    var replies: [FeedNote] = []
    var tagged: [FeedNote] = []
}

/// Full screen on iPhone and iPad, a sized sheet on the Mac.
private struct FollowListHost<Page: View>: ViewModifier {
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
