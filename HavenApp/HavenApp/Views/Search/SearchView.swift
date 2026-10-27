import SwiftUI
import Combine

// MARK: - SearchView

struct SearchView: View {
    @StateObject var feedService = FeedService.shared
    @EnvironmentObject var relayManager: RelayProcessManager
    @Environment(\.openURL) var openURL
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var nostrService: NostrService

    @State var searchQuery: String = ""
    @State var resultTypeFilter: ResultTypeFilter = .all
    /// Who/when filter. Applied to `globalSnapshot` on the device, so a
    /// change never re-asks the relays.
    @State var searchFilter: SearchFilter = .all
    @State var searchResults: SearchResults = .empty
    @State var isSearching = false
    @State var searchDebounceTask: Task<Void, Never>?
    @State var showingNoteDetail: FeedNote?
    /// Non-nil when an iPad split pane owns the note detail column.
    @Environment(\.noteDetailSelection) var noteDetailSelection
    @State var showingProfile: String?
    @State var showingMediaUrl: IdentifiableURL?
    @Namespace private var mediaZoom
    @State var pendingDirectNoteId: String?
    @State private var showingCompose = false
    @State var recentSearches: [String] = UserDefaults.standard.stringArray(forKey: "recentSearches") ?? []
    @State var cachedTrending: [String] = []
    @State var cachedSuggested: [(String, FeedProfile)] = []
    @State var lastDiscoveryRefresh: Date = .distantPast
    @State var cachedRecommendedPeople: [SearchRecommendations.Person] = []
    @State var cachedTopics: [String] = []
    @State var cachedPickedNotes: [FeedNote] = []
    /// Global search: one status per source, streamed with the results.
    @State var globalSources: [GlobalSearchSourceStatus] = []
    /// The latest unfiltered answer, kept so `searchFilter` can be re-applied.
    @State var globalSnapshot: GlobalSearchSnapshot?
    @State var globalFinished = true
    /// Cancels Global search when this view is really gone. Not `onDisappear`:
    /// that also fires when a result is opened on top, and the search (and the
    /// results already shown) must survive the round trip.
    @StateObject var globalSearchLifetime = GlobalSearchLifetime()
    @FocusState private var searchFieldFocused: Bool
    /// On screen now. A TabView keeps a visited tab alive, so a Search tab
    /// sitting behind Feed still hears ⌘F's notification; only the one
    /// showing may take the request, or it is spent off screen.
    @State private var isShowing = false

    enum ResultTypeFilter: CaseIterable {
        case all, users, notes, hashtags, links

        var label: String {
            switch self {
            case .all: return "All"
            case .users: return "Users"
            case .notes: return "Notes"
            case .hashtags: return "Hashtags"
            case .links: return "Links"
            }
        }

        var icon: String {
            switch self {
            case .all: return "square.grid.2x2"
            case .users: return "person.2"
            case .notes: return "note.text"
            case .hashtags: return "number"
            case .links: return "link"
            }
        }
    }

    struct SearchResults {
        var users: [String: FeedProfile] = [:]
        /// Display order for `users` when it matters (Global search is ranked
        /// own → follows → everyone). Empty: sorted by pubkey.
        var userOrder: [String] = []
        var notes: [FeedNote] = []
        var links: [SearchLink] = []
        var hashtags: [String] = []

        static let empty = SearchResults()

        var isEmpty: Bool {
            users.isEmpty && notes.isEmpty && links.isEmpty && hashtags.isEmpty
        }

        var orderedUsers: [(key: String, value: FeedProfile)] {
            guard !userOrder.isEmpty else { return users.sorted(by: { $0.key < $1.key }) }
            return userOrder.compactMap { key in users[key].map { (key: key, value: $0) } }
        }

        /// Whether the section the user is currently looking at is empty. The
        /// results as a whole can be non-empty while the selected tab has
        /// nothing in it, and a blank screen in that case reads as a bug.
        func isEmpty(for filter: ResultTypeFilter) -> Bool {
            switch filter {
            case .all: return isEmpty
            case .users: return users.isEmpty
            case .notes: return notes.isEmpty
            case .hashtags: return hashtags.isEmpty
            case .links: return links.isEmpty
            }
        }
    }

    struct SearchLink {
        let url: String
        let title: String
        let noteId: String
    }

    var body: some View {
        ZStack {
            Color.platformWindowBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // Search header
                VStack(spacing: 12) {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .font(.appSystem(size: 16, weight: .semibold))
                            .foregroundColor(.secondary)

                        TextField("Search users, notes, hashtags...", text: $searchQuery)
                            .textFieldStyle(.plain)
                            .font(.appSystem(size: 14))
                            .focused($searchFieldFocused)
                            #if os(iOS)
                            .submitLabel(.search)
                            .onSubmit { searchFieldFocused = false }
                            #else
                            // Return searches immediately instead of waiting out the
                            // 300ms debounce; Escape clears the field and the results.
                            .onSubmit {
                                // "#bitcoin" opens the hashtag's feed instead of a word search.
                                let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                                if q.hasPrefix("#"), q.count > 2, !q.dropFirst().contains(where: { $0.isWhitespace || $0 == "#" }),
                                   let url = HashtagLink.url(for: String(q.dropFirst())) {
                                    openURL(url)
                                } else {
                                    searchNow()
                                }
                            }
                            .onKeyPress(.escape) {
                                guard !searchQuery.isEmpty else { return .ignored }
                                clearSearch()
                                return .handled
                            }
                            #endif
                            .onChange(of: searchQuery) { _, query in
                                searchDebounceTask?.cancel()
                                let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
                                if trimmed.isEmpty {
                                    searchResults = .empty
                                    pendingDirectNoteId = nil
                                    isSearching = false
                                    globalSources = []
                                    globalSnapshot = nil
                                    globalFinished = true
                                    nostrService.cancelGlobalSearch()
                                    refreshDiscovery(force: true)
                                    return
                                }
                                searchDebounceTask = Task {
                                    try? await Task.sleep(nanoseconds: 300_000_000)
                                    guard !Task.isCancelled else { return }
                                    performSearch(query: query)
                                    saveRecentSearch(query)
                                }
                            }

                        if !searchQuery.isEmpty {
                            Button(action: {
                                clearSearch()
                                #if os(iOS)
                                searchFieldFocused = false
                                #endif
                            }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.appSystem(size: 14))
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(10)

                    SearchFilterCaption(scope: $searchFilter, color: .havenPurple)
                        .animation(Motion.toggle, value: searchFilter)

                    #if os(macOS)
                    // macOS has no glass toolbar — keep the filters inline.
                    HStack(spacing: 12) {
                        // Result type filters
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(ResultTypeFilter.allCases, id: \.self) { filter in
                                    Button(action: { resultTypeFilter = filter }) {
                                        HStack(spacing: 4) {
                                            Image(systemName: filter.icon)
                                                .font(.appSystem(size: 10, weight: .semibold))
                                            Text(filter.label)
                                                .font(.appSystem(size: 12, weight: .semibold))
                                        }
                                        .foregroundColor(resultTypeFilter == filter ? .white : .secondary)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(resultTypeFilter == filter ? Color.havenPurple : Color.secondary.opacity(0.12))
                                        .cornerRadius(6)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }

                        Spacer(minLength: 0)

                        // Who / when
                        SearchFilterMenu(scope: $searchFilter, color: .havenPurple)
                    }
                    #endif
                }
                .padding()
                .background(Color.platformWindowBackground)

                Divider()

                // Results
                if searchQuery.isEmpty {
                    emptyState
                } else if !globalSources.isEmpty {
                    // Global streams: the source strip stays up while results
                    // arrive, and "no results" waits until every source is done.
                    VStack(spacing: 0) {
                        globalSourceStrip
                        Divider()
                        if !searchResults.isEmpty {
                            resultsContent
                        } else if globalFinished {
                            noResultsState
                        } else {
                            loadingState
                        }
                    }
                } else if isSearching {
                    loadingState
                } else if searchResults.isEmpty {
                    noResultsState
                } else {
                    resultsContent
                }
            }
        }
        #if os(iOS)
        .onTapGesture {
            searchFieldFocused = false
        }
        .overlay(alignment: .bottomTrailing) {
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
        .toolbar {
            // Left glass pill: result-type filters
            ToolbarItem(placement: .navigationBarLeading) {
                HStack(spacing: 8) {
                    ForEach(ResultTypeFilter.allCases, id: \.self) { filter in
                        IconFilterButton(
                            icon: filter.icon,
                            tooltip: filter.label,
                            isSelected: resultTypeFilter == filter,
                            color: .havenPurple
                        ) {
                            resultTypeFilter = filter
                        }
                    }
                }
            }
            // Right glass pill: who / when filter
            ToolbarItem(placement: .navigationBarTrailing) {
                SearchFilterMenu(scope: $searchFilter, color: .havenPurple)
            }
        }
        #endif
        .onChange(of: searchFilter) { _, _ in
            applySearchFilter()
        }
        .onReceive(NotificationCenter.default.publisher(for: .composeFromTabBar)) { note in
            guard (note.object as? Int) == 1 else { return }
            showingCompose = true
        }
        .sheet(isPresented: $showingCompose) {
            ComposeView(onDismiss: { showingCompose = false })
                .environmentObject(nostrService)
                .environmentObject(configService)
        }
        .sheet(item: Binding<IdentifiableString?>(
            get: { showingProfile.map { IdentifiableString(id: $0) } },
            set: { showingProfile = $0?.id }
        )) { profile in
            ProfileView(pubkey: profile.id, onDismiss: { showingProfile = nil })
                .environmentObject(nostrService)
                .environmentObject(configService)
                #if os(macOS)
                // Without a minimum, a macOS sheet takes its content's ideal size, which
                // for a profile is small enough to be unusable.
                .frame(minWidth: 520, minHeight: 560)
                #endif
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
        .mediaViewer(item: $showingMediaUrl, namespace: mediaZoom)
        .hashtagLinks()
        // ⌘F on an iPad keyboard while Search is already showing; otherwise
        // the switch makes it appear and onAppear takes the request.
        .onReceive(NotificationCenter.default.publisher(for: .havenFocusSearch)) { _ in
            if isShowing, SearchFocusRequest.take() { searchFieldFocused = true }
        }
        .onDisappear { isShowing = false }
        .onAppear {
            isShowing = true
            InterestListService.shared.refreshIfNeeded()
            refreshDiscovery(force: true)
            if SearchFocusRequest.take() {
                // Focus set during the appear pass is dropped; the next turn holds.
                DispatchQueue.main.async { searchFieldFocused = true }
            }
            #if os(macOS)
            // No tap-to-focus convention on the desktop: the field a window opens
            // on should already be taking keystrokes.
            searchFieldFocused = true
            #endif
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("BlockedAccountsUpdated"))) { _ in
            // Someone was just blocked (or unblocked): redo the open search and
            // the suggestions so the change shows at once.
            refreshDiscovery(force: true)
            if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                performSearch(query: searchQuery)
            }
        }
        .onReceive(feedService.$notes) { notes in
            // Throttled refresh of the empty-state discovery lists as the feed grows.
            refreshDiscovery()

            guard let noteId = pendingDirectNoteId else { return }
            // An naddr waits on a coordinate, which only findNote resolves.
            if let note = notes.first(where: { $0.id == noteId }) ?? feedService.findNote(id: noteId) {
                pendingDirectNoteId = nil
                isSearching = false
                openNote(note)
            }
        }
        .onReceive(InterestListService.shared.$hashtags.dropFirst()) { _ in
            // Following or unfollowing a topic changes what "For you" picks.
            refreshDiscovery(force: true)
        }
        .onReceive(feedService.$wotVouches.dropFirst()) { _ in
            refreshDiscovery(force: true)
        }
        .onReceive(feedService.$parentNotesCache) { cache in
            guard let noteId = pendingDirectNoteId else { return }
            if let note = cache[noteId] ?? feedService.findNote(id: noteId) {
                pendingDirectNoteId = nil
                isSearching = false
                openNote(note)
            }
        }
    }
}

/// Owned by `SearchView` as a `@StateObject`, so it is released only when the
/// view leaves the hierarchy for good — then the Global search it started is
/// stopped. A push or sheet on top keeps it alive.
/// It cancels its own session, not whatever `NostrService` holds, so a new
/// SearchView's search is never stopped by an old one going away.
final class GlobalSearchLifetime: ObservableObject {
    /// Weak: `NostrService` owns the session, and the session's update
    /// closure captures this view — a strong reference here would be a cycle
    /// that keeps this object (and so the search) alive past the view.
    /// Not @Published: setting it must not re-render the view.
    weak var session: GlobalSearchSession?

    deinit {
        session?.cancel()
    }
}
