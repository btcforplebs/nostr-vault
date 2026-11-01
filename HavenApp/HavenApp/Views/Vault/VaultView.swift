import SwiftUI
import PhotosUI

struct VaultView: View {

    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var relayManager: RelayProcessManager
    @ObservedObject var vaultSection = VaultSection.shared
    @StateObject var feedService = FeedService.shared
    /// The openURL around this tab, for #hashtag links (see nostrLinkAction).
    @Environment(\.openURL) var inheritedOpenURL

    @State var navigationPath = NavigationPath()
    /// Whether the search bar is open. While it is, the Vault shows what
    /// the search found in place of its list.
    @State var isSearchActive = false
    @State var searchQueryDraft = ""
    /// Bumped to put the cursor back in the open search bar.
    @State var searchFocusRequest = 0
    @StateObject var vaultSearch = VaultSearchModel()
    /// The phone and iPad open the Vault tab on "Vault", everything new in
    /// one list. The Mac's relay page has no such list.
    #if os(iOS)
    @State var viewMode: ViewMode = .activity
    #else
    @State var viewMode: ViewMode = .notes
    #endif

    @State var initialLoad = false
    @State var isLoadingMore = false
    @State var contentFilter: ContentFilter = .all
    @State var activityFilter: ActivityFilter = .all
    /// The line under the toolbar after a filter tap.
    @StateObject var filterNote = FilterNoteModel()
    /// A filter tap whose list is still being rebuilt; its note waits for
    /// the count.
    @State var pendingFilterNote: VaultFilterChoice?
    /// Bumped each time a rebuilt list lands, so a waiting note can count it.
    @State var displayPass = 0
    /// Notes, Articles or Highlights. Only the Vault tab's mode menu changes it.
    @State var noteScope: VaultNoteScope = .notes
    /// Articles only: just the recipes.
    @State var recipesOnly = false
    /// Articles or Highlights asked for an older page and got nothing back.
    @State var noOlderPages: Set<VaultNoteScope> = []
    @State var isLoadingOlder = false
    /// The Vault tab is showing Media, so none of this view's lists is in sight.
    @State var vaultShowsMedia = false
    @State var likesFilter: LikesFilter = .onMyNotes
    @State var zapsFilter: ZapsFilter = .onMyNotes
    @State var followersFilter: FollowersFilter = .new
    @State var followerSnapshot: FollowerSnapshot?

    // Cached display data (computed in background)
    @State var displayNotes: [NostrEvent] = []
    /// The "Vault" list's lines, newest first.
    @State var displayActivity: [VaultActivity] = []
    /// The picture a Vault-list thumbnail opened in the media viewer.
    @State var showingMediaUrl: IdentifiableURL?
    @Namespace var mediaZoom
    @State var activityHasLoadedOnce = false
    /// Lines newer than this (unix seconds) are new since your last visit.
    @State var activityUnreadSince: Int64 = .max
    /// The account chip picked over the Vault list (VaultAccountChips). Nil
    /// is the active account's own list, as with one account.
    @State var accountChip: VaultAccountChip?
    /// The other accounts' Vault lines, by account hex, before filtering.
    @State var otherAccountActivity: [String: [VaultActivity]] = [:]
    /// Per other account: its lines newer than this are new since its last visit.
    @State var otherAccountUnreadSince: [String: Int64] = [:]
    @State var otherAccountLoading = false
    /// Each filter's limit for the other accounts' read; "load more" raises it.
    @State var otherAccountLimit = VaultAccountChips.otherAccountPage
    /// A filter of the last other-account read came back full: older lines
    /// are there to read.
    @State var otherAccountReadFull = false
    @State var otherAccountLoadTask: Task<Void, Never>?
    @State var displayLikedNotes: [NostrEvent] = []
    /// Maps note ID -> list of (reactor pubkey, reaction emoji) tuples
    @State var reactionMap: [String: [(pubkey: String, emoji: String)]] = [:]
    /// Maps note ID -> most recent reaction date
    @State var latestReactionDates: [String: Date] = [:]
    @State var displayZappedNotes: [NostrEvent] = []
    /// Maps note ID -> list of (zapper pubkey, amount in sats)
    @State var zapMap: [String: [(pubkey: String, amount: Int64)]] = [:]
    /// Maps note ID -> list of pubkeys who reposted it
    @State var repostMap: [String: [String]] = [:]
    /// Maps note ID -> list of pubkeys who quoted it
    @State var quoteMap: [String: [String]] = [:]

    // Stable loading state so the empty-state message doesn't flash
    // before the display data has been computed at least once per tab.
    @State var notesHasLoadedOnce: Bool = false
    @State var likesHasLoadedOnce: Bool = false
    @State var likesInitialSettled: Bool = false
    @State var likesSettleTask: Task<Void, Never>?
    @State var zapsHasLoadedOnce: Bool = false
    @State var zapsInitialSettled: Bool = false
    @State var zapsSettleTask: Task<Void, Never>?

    // Debounce refreshAll() to prevent rapid-fire resubscriptions
    @State var refreshDebounceTask: Task<Void, Never>?
    // Set when a .full refresh is requested during the debounce window so a
    // later .incremental request can't downgrade it.
    @State var pendingFullRefresh = false

    // New-event notification highlights for mode buttons
    @State var hasNewNotes = false
    @State var hasNewLikes = false
    @State var hasNewZaps = false
    @State var hasNewFollowers = false
    @State var notificationBaseline: [Int: Int] = [:] // event kind -> count
    @State var hasEstablishedNotificationBaseline = false

    @State var showingNoteId: String?
    /// The row a tapped notification landed on, outlined for a few seconds.
    @State var focusedEventId: String?
    @State var focusTask: Task<Void, Never>?
    /// Non-nil when an iPad split pane owns the note detail column.
    @Environment(\.noteDetailSelection) var noteDetailSelection
    @Environment(\.inVaultTab) var vaultTabHostsMedia

    /// Opens a note in the split pane's detail column when there is one, and
    /// falls back to the full-screen sheet everywhere else.
    func openNote(_ id: String) {
        if let noteDetailSelection {
            noteDetailSelection.select(id: id)
        } else {
            showingNoteId = id
        }
    }
    @State var showingProfilePubkey: String?
    @State var maxDisplayedItems: Int = 100
    @State var isCopied = false
    @State var requestedMissingIds = Set<String>()
    @State var requestedMissingZapNoteIds = Set<String>()
    /// Cache of parsed zap receipt data keyed by receipt event ID.
    /// Avoids re-parsing JSON description tags on every updateDisplayData cycle.
    @State var zapReceiptCache: [String: ParsedZapReceipt] = [:]
    /// Posts you zapped, read from the wallet's payment history (NWC), newest
    /// payment first. Most zap receipts never tag the sender, so relays alone
    /// leave "Given" empty; the wallet knows every zap it paid.
    @State var walletGivenNotes: [NostrEvent] = []
    /// Post id -> sats you paid it, from the same wallet history.
    @State var walletGivenAmounts: [String: Int64] = [:]
    /// Post id -> when you last paid a zap on it (unix seconds).
    @State var walletGivenTimes: [String: Int64] = [:]
    /// Account + wallet the wallet history was read for; nil until it was.
    @State var walletGivenKey: String?
    @State var walletGivenLoading = false

    @AppStorage("viewerNoteLayoutMode") var noteLayoutMode: NoteLayoutMode = .expanded

    enum NoteLayoutMode: String {
        case expanded
        case compact
    }

    /// The phone's Relay tab has no layout switch, so it always shows full
    /// rows; a "compact" left in storage from the old toggle would otherwise
    /// be stuck on with no way off. The Mac keeps its toggle.
    var rowLayoutMode: NoteLayoutMode {
        #if os(iOS)
        return .expanded
        #else
        return noteLayoutMode
        #endif
    }

    // Debounce mechanism for updateDisplayData
    @State var updateTask: Task<Void, Never>?
    @State var updateGeneration: Int = 0
    @State var showingRelayDashboard = false
    /// The `eventsResetGeneration` the extended zap receipts were fetched in;
    /// nil until the first fetch. A refresh anywhere (this tab, Media) wipes
    /// the receipts pulled from feed relays, so a stale generation refetches.
    @State var zapReceiptsFetchGeneration: Int?
    /// The `eventsResetGeneration` `requestedMissingIds` belongs to.
    @State var likedNotesFetchGeneration: Int?

    // Static regex pattern to avoid recompilation
    /// Scroll target for tapping the Relay tab again.
    static let topAnchor = "vaultTop"
    nonisolated static let hexPattern = try! NSRegularExpression(pattern: "[a-f0-9]{64}", options: .caseInsensitive)


    var statusColor: Color {
        switch nostrService.connectionColor {
        case "green": return .green
        case "yellow": return .yellow
        case "red": return .red
        default: return .gray
        }
    }

    var currentPageTitle: String {
        switch viewMode {
        case .activity:
            return ""
        case .notes:
            switch contentFilter {
            case .all: return ""
            case .mine: return "My Notes"
            case .tagged: return "Notes I'm Tagged In"
            case .whitelist: return "Whitelisted Notes"
            case .outside: return "Replies From Outside Your Network"
            }
        case .media:
            return ""
        case .likes:
            switch likesFilter {
            case .onMyNotes: return "Likes on My Notes"
            case .myLikes: return "Notes I've Liked"
            }
        case .zaps:
            switch zapsFilter {
            case .onMyNotes: return "Zaps on My Notes"
            case .myZaps: return "Notes I've Zapped"
            }
        case .followers:
            switch followersFilter {
            case .new: return "New Followers"
            case .all: return "All Followers"
            }
        }
    }

    // MARK: - Body

    var body: some View {
        #if os(iOS)
        iOSBody
            // ⌘R on an iPad keyboard, while the Vault tab shows the relay half.
            // Here rather than on iOSContent, whose chain is at the type
            // checker's limit.
            .modifier(RefreshesOnTabCommand(tab: 4, isActive: { !VaultSection.shared.showsMedia }) {
                refreshAll(.incremental)
            })
        #else
        viewContent
        #endif
    }

    #if os(iOS)
    @ViewBuilder
    private var iOSBody: some View {
        if noteDetailSelection != nil {
            // iPad two-pane layout: the enclosing NoteSplitPane owns the detail
            // column, so the vault list must not wrap itself in a stack.
            iOSContent
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.hidden, for: .navigationBar)
        } else {
            NavigationStack(path: $navigationPath) {
                iOSContent
                    .navigationTitle("")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarBackground(.hidden, for: .navigationBar)
                    .navigationDestination(for: FeedNote.self) { note in
                        NoteDetailView(note: note)
                    }
            }
        }
    }
    #endif

    // MARK: - iOS Root Content
    /// Flat content view matching FeedView's rootContent pattern:
    /// toolbar + handlers first, navigation modifiers applied in body.
    private var iOSContent: some View {
        viewContentPlatform
        // Search takes the bar's place: the toolbar steps aside and the
        // search bar opens where its magnifying glass was.
        .safeAreaInset(edge: .top, spacing: 0) {
            if isSearchActive {
                searchBar
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 8)
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                leadingToolbarInline
                    .tutorialAnchor(TutorialContent.vaultModes, isActive: showsVaultTutorialAnchors)
            }
            #if os(iOS)
            ToolbarItem(placement: .navigationBarTrailing) {
                trailingToolbarInline
                    .animation(Motion.toggle, value: viewMode)
            }
            #endif
        }
        #if os(iOS)
        .toolbar(isSearchActive ? .hidden : .automatic, for: .navigationBar)
        #endif
        // The Mac hosts it under its own header (VaultView+Layout).
        #if os(iOS)
        .filterNoteHost(filterNote)
        #endif
        .onChange(of: displayPass) { _, _ in filterListLanded() }
        .onChange(of: activityFilter) { _, _ in
            maxDisplayedItems = 50
            scheduleUpdateDisplayData()
        }
        .onChange(of: viewMode) { _, _ in pendingFilterNote = nil }
        // -- handlers from viewContentBase --
        .onAppear {
            if relayManager.isRunning && !relayManager.isBooting {
                if feedService.followedPubkeys.isEmpty {
                    feedService.refresh()
                }
                let recentlyReconnected: Bool
                if let lastReconnect = nostrService.lastForegroundReconnectTime {
                    recentlyReconnected = Date().timeIntervalSince(lastReconnect) < 3.0
                } else {
                    recentlyReconnected = false
                }
                if nostrService.connectionStatus == "Disconnected" && !recentlyReconnected {
                    refreshAll()
                } else {
                    // Sockets are live: keep them, just ask the embedded relay
                    // to catch up and top up the live subscriptions.
                    refreshAll(.incremental)
                }
                initialLoad = true
                updateDisplayData()
            }
            if !hasEstablishedNotificationBaseline {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    establishNotificationBaseline()
                }
            }
        }
        .onChange(of: relayManager.isBooting) { _, isBooting in
            if !isBooting && relayManager.isRunning {
                refreshAll()
                // A chip picked while the relay was starting read nothing.
                if showsOtherAccounts { loadOtherAccountActivity() }
                initialLoad = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    establishNotificationBaseline()
                }
            }
        }
        .onChange(of: relayManager.isRunning) { _, isRunning in
            if isRunning && !relayManager.isBooting {
                refreshAll()
                if showsOtherAccounts { loadOtherAccountActivity() }
                initialLoad = true
            }
        }
        // -- handlers from viewContentWithHandlers --
        .onChange(of: vaultModesWithNews, initial: true) { _, modes in
            if vaultTabHostsMedia { VaultSection.shared.newModes = modes }
        }
        .onReceive(VaultSection.shared.$showsMedia) { vaultShowsMedia = $0 }
        .task(id: firstPageKey) { loadFirstPageInScope() }
        // The Vault tab's red dot: tapping in opens the list it's for, and a
        // list stops counting as new once it's on screen.
        .onChange(of: vaultSection.opensNewActivity, initial: true) { _, opens in
            if opens { openNewActivity() }
        }
        .onChange(of: modeInSight, initial: true) { old, mode in
            if let mode { relayManager.markRelayViewed(mode) }
            if mode == .activity { activityVisit(arriving: true) } else if old == .activity { activityVisit(arriving: false) }
        }
        .onChange(of: relayManager.newActivityModes) { _, _ in
            if let modeInSight { relayManager.markRelayViewed(modeInSight) }
        }
        // A list is marked seen when you leave it as well as when you arrive,
        // so what came in while you watched doesn't light its dot later.
        .onChange(of: watchedMode) { old, new in
            if let old { markTabViewed(old) }
            if let new { markTabViewed(new) }
        }
        .modifier(VaultChangeHandlers(
            viewMode: viewMode,
            likesFilter: likesFilter,
            zapsFilter: zapsFilter,
            contentFilter: contentFilter,
            noteScopeKey: "\(noteScope.rawValue).\(recipesOnly)",
            eventsCount: nostrService.events.count,
            blacklistedNpubs: configService.config.blockedNpubsPerAccount[configService.config.activeAccountNpub.isEmpty ? configService.config.ownerNpub : configService.config.activeAccountNpub] ?? (configService.config.activeAccountNpub.isEmpty ? configService.config.blacklistedNpubs : []),
            activeAccountNpub: configService.config.activeAccountNpub,
            wotCount: feedService.wotPubkeys.count,
            followCount: feedService.followedPubkeys.count,
            onResetAndUpdate: {
                maxDisplayedItems = 50
                notesHasLoadedOnce = false
                scheduleUpdateDisplayData()
            },
            onUpdate: { scheduleUpdateDisplayData() },
            onViewModeChange: { newMode in
                updateDisplayData()
                markTabViewed(newMode)
                if newMode == .activity {
                    fetchMoreZapReceipts()
                    refreshFollowers()
                }
                if newMode == .likes {
                    fetchMissingLikedNotes()
                    updateLikesSettleState()
                }
                if newMode == .zaps {
                    fetchMoreZapReceipts()
                    fetchMissingZappedNotes()
                    updateZapsSettleState()
                }
            },
            onEventsChange: {
                scheduleUpdateDisplayData()
                checkForNewNotifications()
                if viewMode == .likes && likesFilter == .myLikes {
                    fetchMissingLikedNotes()
                }
                if viewMode == .zaps {
                    fetchMoreZapReceipts()
                    fetchMissingZappedNotes()
                }
            }
        ))
        .onChange(of: likesFilter) { _, _ in
            likesHasLoadedOnce = false
            likesInitialSettled = false
            updateLikesSettleState()
        }
        .onChange(of: zapsFilter) { _, _ in
            zapsHasLoadedOnce = false
            zapsInitialSettled = false
            updateZapsSettleState()
        }
        .onChange(of: configService.config.zapsOnlyMode) { _, newValue in
            if newValue && viewMode == .likes {
                withAnimation(Motion.toggle) { viewMode = .notes }
            }
        }
        // A full refresh empties the lists back to their first page.
        .onChange(of: nostrService.events.isEmpty) { _, empty in
            if empty { noOlderPages = [] }
        }
        // Your accounts tagging each other came in or left the list.
        .onChange(of: configService.config.notifyOwnAccountTags) { _, _ in
            scheduleUpdateDisplayData()
            if showsOtherAccounts { loadOtherAccountActivity() }
        }
        .onChange(of: configService.config.activeAccountNpub) { _, _ in
            notesHasLoadedOnce = false
            activityHasLoadedOnce = false
            noOlderPages = []
            likesHasLoadedOnce = false
            likesInitialSettled = false
            zapsHasLoadedOnce = false
            zapsInitialSettled = false
            zapReceiptsFetchGeneration = nil
            likedNotesFetchGeneration = nil
            zapReceiptCache = [:]
            refreshAll()
        }
        .onChange(of: nostrService.isFetching) { _, _ in
            if viewMode == .likes { updateLikesSettleState() }
            if viewMode == .zaps { updateZapsSettleState() }
        }
        .onChange(of: relayManager.isBooting) { _, _ in
            if viewMode == .likes { updateLikesSettleState() }
            if viewMode == .zaps { updateZapsSettleState() }
        }
        // -- handlers from viewContent --
        .onReceive(NotificationCenter.default.publisher(for: .feedInjectionComplete)) { _ in
            refreshAll(.incremental)
        }
        .onReceive(NotificationCenter.default.publisher(for: .mediaNotFoundChanged)) { _ in
            scheduleUpdateDisplayData()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openRelayDashboard)) { _ in
            showingRelayDashboard = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .havenOpenRelayLikes)) { _ in
            // In Zaps Only mode the Likes tab is hidden — route to Notes instead.
            let target: ViewMode = configService.config.zapsOnlyMode ? .notes : .likes
            withAnimation(Motion.toggle) { viewMode = target }
            if target == .notes { noteScope = .notes; recipesOnly = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: .havenOpenRelayNotes)) { note in
            openNotes(note)
        }
        .onReceive(NotificationCenter.default.publisher(for: .havenOpenRelayZaps)) { _ in
            withAnimation(Motion.toggle) { viewMode = .zaps }
        }
        .onReceive(NotificationCenter.default.publisher(for: .havenOpenRelayFollowers)) { _ in
            withAnimation(Motion.toggle) { viewMode = .followers }
        }
        .onReceive(NotificationCenter.default.publisher(for: .havenOpenRelayActivity)) { _ in
            withAnimation(Motion.toggle) { viewMode = .activity }
        }
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
        .sheet(isPresented: $showingRelayDashboard) {
            NavigationView {
                relayDashboardContent
                    .environmentObject(relayManager)
                    .environmentObject(configService)
                    .environmentObject(nostrService)
                    .environmentObject(StatsService.shared)
                    .navigationTitle("")
                    #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarBackground(.hidden, for: .navigationBar)
                    #endif
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingRelayDashboard = false }
                        }
                        if vaultTabHostsMedia {
                            ToolbarItem(placement: .principal) {
                                Label(VaultDashboard.title, systemImage: VaultDashboard.symbol)
                                    .labelStyle(.titleAndIcon)
                                    .font(.appSystem(size: 17, weight: .bold, design: .rounded))
                            }
                        }
                    }
            }
        }
    }

    /// The Vault tab's dashboard is the Vault Dashboard; the relay-only
    /// layout (macOS keeps notes and media apart) is the relay dashboard.
    @ViewBuilder
    var relayDashboardContent: some View {
        if vaultTabHostsMedia {
            VaultDashboardView()
        } else {
            DashboardView()
        }
    }
}
