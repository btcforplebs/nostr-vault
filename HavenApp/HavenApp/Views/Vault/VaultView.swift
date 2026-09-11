import SwiftUI
import PhotosUI

struct VaultView: View {

    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var relayManager: RelayProcessManager
    @StateObject private var feedService = FeedService.shared

    @State var navigationPath = NavigationPath()
    @State var committedSearch = ""
    @State var searchScope: SearchScope = .notes
    /// Whether the search field is showing. `committedSearch` had no control
    /// anywhere that ever set it — the entire search feature was unreachable.
    @State var isSearchActive = false
    @State var searchQueryDraft = ""
    @State var displayProfileResults: [FeedProfile] = []
    @State var viewMode: ViewMode = .notes

    @State var initialLoad = false
    @State var isLoadingMore = false
    @State var contentFilter: ContentFilter = .all
    @State var likesFilter: LikesFilter = .onMyNotes
    @State var zapsFilter: ZapsFilter = .onMyNotes

    // Cached display data (computed in background)
    @State var displayNotes: [NostrEvent] = []
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
    @State var notificationBaseline: [Int: Int] = [:] // event kind -> count
    @State var hasEstablishedNotificationBaseline = false

    @State var showingNoteId: String?
    /// Non-nil when an iPad split pane owns the note detail column.
    @Environment(\.noteDetailSelection) var noteDetailSelection

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
    #if os(iOS)
    @State var saveToPhotosMessage: String?
    #endif
    @State var isCopied = false
    @State var requestedMissingIds = Set<String>()
    @State var requestedMissingZapNoteIds = Set<String>()
    /// Cache of parsed zap receipt data keyed by receipt event ID.
    /// Avoids re-parsing JSON description tags on every updateDisplayData cycle.
    @State var zapReceiptCache: [String: ParsedZapReceipt] = [:]

    @AppStorage("viewerNoteLayoutMode") var noteLayoutMode: NoteLayoutMode = .expanded

    enum NoteLayoutMode: String {
        case expanded
        case compact
    }

    // Debounce mechanism for updateDisplayData
    @State var updateTask: Task<Void, Never>?
    @State var updateGeneration: Int = 0
    @State var showingRelayDashboard = false
    @State var hasFetchedZapReceipts = false

    // Static regex pattern to avoid recompilation
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
        case .notes:
            switch contentFilter {
            case .all: return ""
            case .mine: return "My Notes"
            case .tagged: return "Notes I'm Tagged In"
            case .whitelist: return "Whitelisted Notes"
            }
        case .media:
            return ""
        case .likes:
            switch likesFilter {
            case .onMyNotes: return "Likes on My Notes"
            case .onTagged: return "Likes on Tagged Notes"
            case .onWhitelisted: return "Likes on Whitelisted Notes"
            case .myLikes: return "Notes I've Liked"
            }
        case .zaps:
            switch zapsFilter {
            case .onMyNotes: return "Zaps on My Notes"
            case .onTagged: return "Zaps on Tagged Notes"
            case .onWhitelisted: return "Zaps on Whitelisted Notes"
            case .myZaps: return "Notes I've Zapped"
            }
        }
    }

    // MARK: - Body

    var body: some View {
        #if os(iOS)
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
        #else
        viewContent
        #endif
    }

    // MARK: - iOS Root Content
    /// Flat content view matching FeedView's rootContent pattern:
    /// toolbar + handlers first, navigation modifiers applied in body.
    private var iOSContent: some View {
        viewContentPlatform
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                leadingToolbarInline
            }
            #if os(iOS)
            ToolbarItem(placement: .navigationBarTrailing) {
                ViewThatFits {
                    // Preferred: full inline icon buttons
                    trailingToolbarInline
                    // Fallback: compact menu with labeled items
                    trailingToolbarMenu
                }
                .animation(Motion.toggle, value: viewMode)
            }
            #else
            ToolbarItem(placement: .automatic) {
                trailingToolbarInline
                    .animation(Motion.toggle, value: viewMode)
            }
            #endif
        }
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
                initialLoad = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    establishNotificationBaseline()
                }
            }
        }
        .onChange(of: relayManager.isRunning) { _, isRunning in
            if isRunning && !relayManager.isBooting {
                refreshAll()
                initialLoad = true
            }
        }
        // -- handlers from viewContentWithHandlers --
        .modifier(VaultChangeHandlers(
            viewMode: viewMode,
            likesFilter: likesFilter,
            zapsFilter: zapsFilter,
            committedSearch: committedSearch,
            searchScope: searchScope,
            contentFilter: contentFilter,
            eventsCount: nostrService.events.count,
            blacklistedNpubs: configService.config.blockedNpubsPerAccount[configService.config.activeAccountNpub.isEmpty ? configService.config.ownerNpub : configService.config.activeAccountNpub] ?? (configService.config.activeAccountNpub.isEmpty ? configService.config.blacklistedNpubs : []),
            activeAccountNpub: configService.config.activeAccountNpub,
            wotCount: feedService.wotPubkeys.count,
            onResetAndUpdate: {
                maxDisplayedItems = 50
                notesHasLoadedOnce = false
                scheduleUpdateDisplayData()
            },
            onUpdate: { scheduleUpdateDisplayData() },
            onViewModeChange: { newMode in
                updateDisplayData()
                markTabViewed(newMode)
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
        .onChange(of: configService.config.activeAccountNpub) { _, _ in
            notesHasLoadedOnce = false
            likesHasLoadedOnce = false
            likesInitialSettled = false
            zapsHasLoadedOnce = false
            zapsInitialSettled = false
            hasFetchedZapReceipts = false
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
        }
        .onReceive(NotificationCenter.default.publisher(for: .havenOpenRelayNotes)) { _ in
            withAnimation(Motion.toggle) { viewMode = .notes }
        }
        .onReceive(NotificationCenter.default.publisher(for: .havenOpenRelayZaps)) { _ in
            withAnimation(Motion.toggle) { viewMode = .zaps }
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
                DashboardView()
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
                    }
            }
        }
    }

    // MARK: - Platform Layout

    @ViewBuilder
    var viewContentPlatform: some View {
        #if os(iOS)
        // Vault tab: full-bleed layout so content scrolls behind
        // the transparent navigation bar, matching the glass toolbar effect.
        ZStack {
            Color.platformWindowBackground.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    listContent

                    if !displayNotes.isEmpty || !displayLikedNotes.isEmpty {
                        Color.clear
                            .frame(height: 1)
                            .padding(.bottom, 20)
                            .onAppear {
                                if !nostrService.isFetching && !displayNotes.isEmpty {
                                    loadMore()
                                }
                            }
                            .id(nostrService.events.count)
                    }
                }
                .tabBarBottomPadding()
            }
            .scrollDismissesKeyboard(.interactively)
            .refreshable {
                refreshAll(.incremental)
            }
            .scrollDirectionTracking(feedService: feedService)
        }
        .overlay(alignment: .bottomTrailing) {
            if !feedService.feedScrollingDown {
                Button(action: { showingRelayDashboard = true }) {
                    HStack(spacing: 6) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.appSystem(size: 15, weight: .bold))
                        Text("Relay")
                            .font(.appSystem(size: 14, weight: .bold, design: .rounded))
                    }
                    .foregroundColor(.white)
                    .frame(height: 48)
                    .padding(.horizontal, 18)
                    .background(
                        Capsule()
                            .fill(statusColor)
                            .shadow(color: statusColor.opacity(0.35), radius: 8, x: 0, y: 4)
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

                if geometry.size.width > 680 {
                    VStack(spacing: 0) {
                        desktopHeaderView

                        Divider()

                        ScrollView {
                            listContent

                            if !displayNotes.isEmpty || !displayLikedNotes.isEmpty {
                                Color.clear
                                    .frame(height: 1)
                                    .padding(.bottom, 20)
                                    .onAppear {
                                        if !nostrService.isFetching && !displayNotes.isEmpty {
                                            loadMore()
                                        }
                                    }
                                    .id(nostrService.events.count)
                            }
                        }
                        .refreshable {
                            refreshAll(.incremental)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .clipped()
                } else {
                    if showingRelayDashboard {
                        VStack(spacing: 0) {
                            HStack {
                                Text("Relay Dashboard")
                                    .font(.appSystem(size: 16, weight: .bold))
                                    .foregroundColor(.primary)
                                Spacer()
                                Button("Done") {
                                    showingRelayDashboard = false
                                }
                                .keyboardShortcut(.defaultAction)
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 14)
                            .background(Color.platformConsoleHeaderBackground)

                            Divider()

                            DashboardView()
                                .environmentObject(relayManager)
                                .environmentObject(configService)
                                .environmentObject(nostrService)
                                .environmentObject(StatsService.shared)
                        }
                    } else {
                        compactViewContent(isNarrow: geometry.size.width < 500)
                    }
                }
            }
        }
        #endif
    }

    // MARK: - Compact View (narrow macOS / fallback)

    @ViewBuilder
    func compactViewContent(isNarrow: Bool) -> some View {
        VStack(spacing: 0) {
            headerView(isNarrow: isNarrow)

            Divider()

            ScrollView {
                VStack(spacing: 0) {
                    listContent

                    if !displayNotes.isEmpty || !displayLikedNotes.isEmpty {
                        Color.clear
                            .frame(height: 1)
                            .padding(.bottom, 20)
                            .onAppear {
                                if !nostrService.isFetching && !displayNotes.isEmpty {
                                    loadMore()
                                }
                            }
                            .id(nostrService.events.count)
                    }
                }
                .tabBarBottomPadding()
            }
            .scrollDismissesKeyboard(.interactively)
            .refreshable {
                refreshAll(.incremental)
            }
            .scrollDirectionTracking(feedService: feedService)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        #if os(iOS)
        .overlay(alignment: .bottomTrailing) {
            if !feedService.feedScrollingDown {
                Button(action: { showingRelayDashboard = true }) {
                    HStack(spacing: 6) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.appSystem(size: 15, weight: .bold))
                        Text("Relay")
                            .font(.appSystem(size: 14, weight: .bold, design: .rounded))
                    }
                    .foregroundColor(.white)
                    .frame(height: 48)
                    .padding(.horizontal, 18)
                    .background(
                        Capsule()
                            .fill(statusColor)
                            .shadow(color: statusColor.opacity(0.35), radius: 8, x: 0, y: 4)
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
                modeView

                Spacer()

                refreshButton

                if viewMode == .notes {
                    filterView
                } else if viewMode == .likes {
                    likesFilterView
                } else if viewMode == .zaps {
                    zapsFilterView
                }

                searchToggleButton
                compactToggleButton
            }

            searchBar
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal)
        .padding(.vertical, 12)
        .background(Color.platformSecondaryGroupedBackground)
    }

    // MARK: - Refresh

    /// `.refreshable` is the vault's only refresh path and macOS has no pull-to-refresh,
    /// so without this the list could only be refreshed by switching accounts or
    /// restarting the relay.
    @ViewBuilder
    var refreshButton: some View {
        IconFilterButton(
            icon: "arrow.clockwise",
            tooltip: "Refresh Vault",
            isSelected: true,
            color: .havenPurple,
            action: { refreshAll(.incremental) }
        )
        .keyboardShortcut("r", modifiers: .command)
    }

    // MARK: - Header View

    @ViewBuilder
    func headerView(isNarrow: Bool) -> some View {
        VStack(spacing: 12) {
            #if os(macOS)
            if isNarrow {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        modeView
                        Spacer()
                        refreshButton
                        searchToggleButton
                    }
                    if viewMode == .notes {
                        ScrollView(.horizontal, showsIndicators: false) {
                            filterView
                        }
                    } else if viewMode == .likes {
                        ScrollView(.horizontal, showsIndicators: false) {
                            likesFilterView
                        }
                    } else if viewMode == .zaps {
                        ScrollView(.horizontal, showsIndicators: false) {
                            zapsFilterView
                        }
                    }
                    searchBar
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        modeView
                        Spacer()
                        if viewMode == .notes {
                            filterView
                        } else if viewMode == .likes {
                            likesFilterView
                        } else if viewMode == .zaps {
                            zapsFilterView
                        }
                        refreshButton
                        searchToggleButton
                        compactToggleButton
                    }
                    searchBar
                }
            }
            #endif
        }
        .frame(maxWidth: .infinity)
        #if os(macOS)
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Color.platformSecondaryGroupedBackground)
        #endif
    }

    // MARK: - macOS viewContent (used for non-iOS body path)

    var viewContent: some View {
        viewContentBase
        .modifier(VaultChangeHandlers(
            viewMode: viewMode,
            likesFilter: likesFilter,
            zapsFilter: zapsFilter,
            committedSearch: committedSearch,
            searchScope: searchScope,
            contentFilter: contentFilter,
            eventsCount: nostrService.events.count,
            blacklistedNpubs: configService.config.blockedNpubsPerAccount[configService.config.activeAccountNpub.isEmpty ? configService.config.ownerNpub : configService.config.activeAccountNpub] ?? (configService.config.activeAccountNpub.isEmpty ? configService.config.blacklistedNpubs : []),
            activeAccountNpub: configService.config.activeAccountNpub,
            wotCount: feedService.wotPubkeys.count,
            onResetAndUpdate: {
                maxDisplayedItems = 50
                notesHasLoadedOnce = false
                scheduleUpdateDisplayData()
            },
            onUpdate: { scheduleUpdateDisplayData() },
            onViewModeChange: { newMode in
                updateDisplayData()
                markTabViewed(newMode)
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
        .onChange(of: configService.config.activeAccountNpub) { _, _ in
            notesHasLoadedOnce = false
            likesHasLoadedOnce = false
            likesInitialSettled = false
            zapsHasLoadedOnce = false
            zapsInitialSettled = false
            hasFetchedZapReceipts = false
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
        .onReceive(NotificationCenter.default.publisher(for: .feedInjectionComplete)) { _ in
            refreshAll(.incremental)
        }
        .onReceive(NotificationCenter.default.publisher(for: .mediaNotFoundChanged)) { _ in
            scheduleUpdateDisplayData()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openRelayDashboard)) { _ in
            showingRelayDashboard = true
        }
        // Not iOS-only: this is the macOS body, and gating these meant a notification
        // tap that reached the Notes tab still showed whatever mode was last open.
        .onReceive(NotificationCenter.default.publisher(for: .havenOpenRelayLikes)) { _ in
            // In Zaps Only mode the Likes tab is hidden — route to Notes instead.
            let target: ViewMode = configService.config.zapsOnlyMode ? .notes : .likes
            withAnimation(Motion.toggle) { viewMode = target }
        }
        .onReceive(NotificationCenter.default.publisher(for: .havenOpenRelayNotes)) { _ in
            withAnimation(Motion.toggle) { viewMode = .notes }
        }
        .onReceive(NotificationCenter.default.publisher(for: .havenOpenRelayZaps)) { _ in
            withAnimation(Motion.toggle) { viewMode = .zaps }
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
        #if os(iOS)
        .sheet(isPresented: $showingRelayDashboard) {
            NavigationView {
                DashboardView()
                    .environmentObject(relayManager)
                    .environmentObject(configService)
                    .environmentObject(nostrService)
                    .environmentObject(StatsService.shared)
                    .navigationTitle("")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarBackground(.hidden, for: .navigationBar)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingRelayDashboard = false }
                        }
                    }
            }
        }
        #endif
    }

    private var viewContentBase: some View {
        viewContentPlatform
        .onAppear {
            if relayManager.isRunning && !relayManager.isBooting {
                if feedService.followedPubkeys.isEmpty {
                    feedService.refresh()
                }
                // Only refresh if SceneDelegate didn't already handle reconnection
                // within the last 3 seconds (prevents double-reset race condition)
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
                // Eagerly compute display data so tabs don't flash an empty state
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
                initialLoad = true
                // Re-establish baseline after boot settles so initial events don't trigger highlights
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    establishNotificationBaseline()
                }
            }
        }
        .onChange(of: relayManager.isRunning) { _, isRunning in
            if isRunning && !relayManager.isBooting {
                refreshAll()
                initialLoad = true
            }
        }
    }
}
