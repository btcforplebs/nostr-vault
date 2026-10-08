import SwiftUI
import Combine

// MARK: - SearchView

struct SearchView: View {
    @StateObject private var feedService = FeedService.shared
    @EnvironmentObject var relayManager: RelayProcessManager
    @Environment(\.openURL) private var openURL
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var nostrService: NostrService

    @State private var searchQuery: String = ""
    @State private var resultTypeFilter: ResultTypeFilter = .all
    @State private var searchMode: SearchMode = .relay
    @State private var searchResults: SearchResults = .empty
    @State private var isSearching = false
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var showingNoteDetail: FeedNote?
    /// Non-nil when an iPad split pane owns the note detail column.
    @Environment(\.noteDetailSelection) private var noteDetailSelection
    @State private var showingProfile: String?
    @State private var showingMediaUrl: IdentifiableURL?
    @Namespace private var mediaZoom
    @State private var pendingDirectNoteId: String?
    @State private var showingCompose = false
    @State private var recentSearches: [String] = UserDefaults.standard.stringArray(forKey: "recentSearches") ?? []
    @State private var cachedTrending: [String] = []
    @State private var cachedSuggested: [(String, FeedProfile)] = []
    @State private var lastDiscoveryRefresh: Date = .distantPast
    /// Global search: one status per source, streamed with the results.
    @State private var globalSources: [GlobalSearchSourceStatus] = []
    @State private var globalFinished = true
    /// Cancels Global search when this view is really gone. Not `onDisappear`:
    /// that also fires when a result is opened on top, and the search (and the
    /// results already shown) must survive the round trip.
    @StateObject private var globalSearchLifetime = GlobalSearchLifetime()
    @FocusState private var searchFieldFocused: Bool

    enum SearchMode: CaseIterable {
        case relay, global

        var label: String {
            switch self {
            case .relay: return "Relay"
            case .global: return "Global"
            }
        }

        var icon: String {
            switch self {
            case .relay: return "externaldrive.connected.to.line.below"
            case .global: return "globe"
            }
        }
    }

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
        /// own → follows → everyone). Empty: sorted by pubkey, as relay mode is.
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

    private func saveRecentSearch(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return }
        recentSearches.removeAll { $0.lowercased() == trimmed.lowercased() }
        recentSearches.insert(trimmed, at: 0)
        if recentSearches.count > 8 { recentSearches = Array(recentSearches.prefix(8)) }
        UserDefaults.standard.set(recentSearches, forKey: "recentSearches")
    }

    private func computeTrendingHashtags() -> [String] {
        var counts: [String: Int] = [:]
        for note in feedService.notes {
            for tag in note.tags where tag.count >= 2 && tag[0] == "t" {
                let hashtag = tag[1].lowercased()
                counts[hashtag, default: 0] += 1
            }
        }
        return counts.sorted { $0.value > $1.value }.prefix(8).map { $0.key }
    }

    private func computeSuggestedProfiles() -> [(String, FeedProfile)] {
        // Profiles that appear most in the feed (most active posters)
        var postCounts: [String: Int] = [:]
        for note in feedService.notes {
            postCounts[note.pubkey, default: 0] += 1
        }
        let ownPubkey = configService.activeAccountHexPubkey
        return postCounts
            .filter { $0.key != ownPubkey }
            .sorted { $0.value > $1.value }
            .prefix(6)
            .compactMap { pubkey, _ in
                guard let profile = nostrService.profiles[pubkey],
                      profile.name != nil || profile.displayName != nil else { return nil }
                return (pubkey, profile)
            }
    }

    /// Recomputes the empty-state discovery lists (trending hashtags + suggested
    /// profiles) into cached state. The feed streams events continuously, so these
    /// are throttled to avoid the empty state reshuffling on every published change.
    private func refreshDiscovery(force: Bool = false) {
        guard searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastDiscoveryRefresh) >= 5 else { return }
        lastDiscoveryRefresh = now
        cachedTrending = computeTrendingHashtags()
        cachedSuggested = computeSuggestedProfiles()
    }

    /// Opens a note in the split pane's detail column when there is one, and
    /// falls back to the sheet everywhere else.
    private func openNote(_ note: FeedNote) {
        if let noteDetailSelection {
            noteDetailSelection.select(note)
        } else {
            showingNoteDetail = note
        }
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
                                    globalFinished = true
                                    nostrService.cancelGlobalSearch()
                                    nostrService.cancelLocalRelaySearch()
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

                    #if os(macOS)
                    // macOS has no glass toolbar — keep filters/mode inline.
                    HStack(spacing: 12) {
                        // Search source: relay vs global
                        HStack(spacing: 6) {
                            ForEach(SearchMode.allCases, id: \.self) { mode in
                                modeChip(mode)
                            }
                        }

                        Divider()
                            .frame(height: 16)

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
                    }
                    #endif
                }
                .padding()
                .background(Color.platformWindowBackground)

                Divider()

                // Results
                if searchQuery.isEmpty {
                    emptyState
                } else if searchMode == .global && !globalSources.isEmpty {
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
            // Right glass pill: search source (relay vs global)
            ToolbarItem(placement: .navigationBarTrailing) {
                ViewThatFits {
                    HStack(spacing: 8) {
                        ForEach(SearchMode.allCases, id: \.self) { mode in
                            IconFilterButton(
                                icon: mode.icon,
                                tooltip: mode.label,
                                isSelected: searchMode == mode,
                                color: .havenPurple
                            ) {
                                guard searchMode != mode else { return }
                                searchMode = mode
                                rerunSearch()
                            }
                        }
                    }

                    Menu {
                        ForEach(SearchMode.allCases, id: \.self) { mode in
                            Button {
                                guard searchMode != mode else { return }
                                searchMode = mode
                                rerunSearch()
                            } label: {
                                Label(mode.label, systemImage: mode.icon)
                            }
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease")
                            .font(.appSystem(size: 15, weight: .semibold))
                            .foregroundColor(.havenPurple)
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                }
            }
        }
        #endif
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
        .onAppear {
            refreshDiscovery(force: true)
            #if os(macOS)
            // No tap-to-focus convention on the desktop: the field a window opens
            // on should already be taking keystrokes.
            searchFieldFocused = true
            #endif
        }
        .onReceive(feedService.$notes) { notes in
            // Throttled refresh of the empty-state discovery lists as the feed grows.
            refreshDiscovery()

            guard let noteId = pendingDirectNoteId else { return }
            if let note = notes.first(where: { $0.id == noteId }) {
                pendingDirectNoteId = nil
                isSearching = false
                openNote(note)
            }
        }
        .onReceive(feedService.$parentNotesCache) { cache in
            guard let noteId = pendingDirectNoteId else { return }
            if let note = cache[noteId] {
                pendingDirectNoteId = nil
                isSearching = false
                openNote(note)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Recent searches
                if !recentSearches.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Recent")
                                .font(.appSystem(size: 13, weight: .semibold))
                                .foregroundColor(.secondary)
                            Spacer()
                            Button("Clear") {
                                recentSearches = []
                                UserDefaults.standard.removeObject(forKey: "recentSearches")
                            }
                            .font(.appSystem(size: 12))
                            .foregroundColor(.secondary.opacity(0.7))
                            .buttonStyle(.plain)
                        }

                        FlowLayout(spacing: 6) {
                            ForEach(recentSearches, id: \.self) { query in
                                Button(action: { searchQuery = query }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "clock.arrow.circlepath")
                                            .font(.appSystem(size: 10))
                                        Text(query)
                                            .font(.appSystem(size: 12, weight: .medium))
                                    }
                                    .foregroundColor(.primary.opacity(0.8))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color.secondary.opacity(0.12))
                                    .cornerRadius(14)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                // Trending hashtags
                let trending = cachedTrending
                if !trending.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Trending")
                            .font(.appSystem(size: 13, weight: .semibold))
                            .foregroundColor(.secondary)

                        FlowLayout(spacing: 6) {
                            ForEach(trending, id: \.self) { tag in
                                Button(action: { searchQuery = "#\(tag)" }) {
                                    Text("#\(tag)")
                                        .font(.appSystem(size: 12, weight: .medium))
                                        .foregroundColor(Color.havenPurple)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(Color.havenPurple.opacity(0.12))
                                        .cornerRadius(14)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                // Suggested profiles
                let suggested = cachedSuggested
                if !suggested.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Active in your feed")
                            .font(.appSystem(size: 13, weight: .semibold))
                            .foregroundColor(.secondary)

                        VStack(spacing: 4) {
                            ForEach(suggested, id: \.0) { pubkey, profile in
                                Button(action: { showingProfile = pubkey }) {
                                    HStack(spacing: 10) {
                                        AvatarView(url: profile.pictureURL, pubkey: pubkey, size: 34)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(profile.bestName)
                                                .font(.appSystem(size: 13, weight: .medium))
                                                .foregroundColor(.primary)
                                                .lineLimit(1)
                                            if let nip05 = profile.nip05, !nip05.isEmpty {
                                                Text(nip05)
                                                    .font(.appSystem(size: 11))
                                                    .foregroundColor(.secondary)
                                                    .lineLimit(1)
                                            }
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.appSystem(size: 11, weight: .semibold))
                                            .foregroundColor(.secondary.opacity(0.5))
                                    }
                                    .padding(.vertical, 6)
                                    .padding(.horizontal, 8)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                // Fallback if nothing to show
                if recentSearches.isEmpty && trending.isEmpty && suggested.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "magnifyingglass")
                            .font(.appSystem(size: 48, weight: .thin))
                            .foregroundColor(.secondary.opacity(0.5))
                        VStack(spacing: 8) {
                            Text("Search")
                                .font(.appSystem(size: 18, weight: .semibold))
                                .foregroundColor(.primary)
                            Text("Find users, notes, hashtags and links\nOr paste a note1 or nevent1 ID")
                                .font(.appSystem(size: 13))
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                }
            }
            .padding()
        }
        .scrollDirectionTracking(feedService: feedService)
    }

    /// Simple wrapping layout for chips
    private struct FlowLayout: Layout {
        var spacing: CGFloat = 6

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            let width = proposal.width ?? .infinity
            var x: CGFloat = 0
            var y: CGFloat = 0
            var rowHeight: CGFloat = 0

            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)
                if x + size.width > width && x > 0 {
                    x = 0
                    y += rowHeight + spacing
                    rowHeight = 0
                }
                x += size.width + spacing
                rowHeight = max(rowHeight, size.height)
            }
            return CGSize(width: width, height: y + rowHeight)
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            var x: CGFloat = bounds.minX
            var y: CGFloat = bounds.minY
            var rowHeight: CGFloat = 0

            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)
                if x + size.width > bounds.maxX && x > bounds.minX {
                    x = bounds.minX
                    y += rowHeight + spacing
                    rowHeight = 0
                }
                subview.place(at: CGPoint(x: x, y: y), proposal: .init(size))
                x += size.width + spacing
                rowHeight = max(rowHeight, size.height)
            }
        }
    }

    /// One chip per Global search source: searching / N found / no answer.
    @ViewBuilder
    private var globalSourceStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(globalSources) { source in
                    globalSourceChip(source)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func globalSourceChip(_ source: GlobalSearchSourceStatus) -> some View {
        let (text, color): (String, Color) = {
            switch source.state {
            case .searching: return (source.count > 0 ? "\(source.count) so far" : "searching", .secondary)
            case .found(let n): return ("\(n) found", n > 0 ? .havenOnline : .secondary)
            case .noAnswer(let reason): return ("no answer: \(reason)", .orange)
            }
        }()
        let icon: String = {
            switch source.role {
            case .device:
                #if os(macOS)
                return "desktopcomputer"
                #else
                return "iphone"
                #endif
            case .mac: return "desktopcomputer"
            case .relay: return "antenna.radiowaves.left.and.right"
            }
        }()
        HStack(spacing: 5) {
            if case .searching = source.state {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Image(systemName: icon)
                    .font(.appSystem(size: 10, weight: .semibold))
                    .foregroundColor(color)
            }
            Text(source.label)
                .font(.appSystem(size: 11, weight: .semibold))
                .foregroundColor(.primary.opacity(0.85))
            if let detail = source.detail {
                Text(detail)
                    .font(.appSystem(size: 10))
                    .foregroundColor(.secondary)
            }
            Text(text)
                .font(.appSystem(size: 11))
                .foregroundColor(color)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(12)
        .help("\(source.label): \(text)")
    }

    @ViewBuilder
    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
                .tint(Color.havenPurple)
            if pendingDirectNoteId != nil {
                Text("Looking up note...")
                    .font(.appSystem(size: 13))
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var noResultsState: some View {
        VStack(spacing: 16) {
            Image(systemName: "magnifyingglass")
                .font(.appSystem(size: 32, weight: .thin))
                .foregroundColor(.secondary.opacity(0.5))

            Text("No results found")
                .font(.appSystem(size: 14, weight: .semibold))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    @ViewBuilder
    private var resultsContent: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Users section
                if (resultTypeFilter == .all || resultTypeFilter == .users) && !searchResults.users.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Users")
                            .font(.appSystem(size: 13, weight: .semibold))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 16)

                        VStack(spacing: 8) {
                            ForEach(searchResults.orderedUsers, id: \.key) { pubkey, profile in
                                userRow(pubkey: pubkey, profile: profile)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }

                // Notes section
                if (resultTypeFilter == .all || resultTypeFilter == .notes) && !searchResults.notes.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Notes")
                            .font(.appSystem(size: 13, weight: .semibold))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 16)

                        VStack(spacing: 8) {
                            ForEach(searchResults.notes) { note in
                                FeedNoteRow(
                                   note: note,
                                   profile: nostrService.profiles[note.pubkey],
                                   rowData: FeedNoteRowData.resolve(
                                       for: note,
                                       feedService: feedService,
                                       nostrService: nostrService
                                   ),
                                   onProfile: { pubkey in
                                       showingProfile = pubkey
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
                        }
                        .environment(\.feedActions, .make(feedService: feedService, nostrService: nostrService))
                        .padding(.horizontal, 16)
                    }
                }

                // Hashtags section
                if (resultTypeFilter == .all || resultTypeFilter == .hashtags) && !searchResults.hashtags.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Hashtags")
                            .font(.appSystem(size: 13, weight: .semibold))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 16)

                        VStack(spacing: 8) {
                            ForEach(searchResults.hashtags, id: \.self) { hashtag in
                                hashtagRow(hashtag: hashtag)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }

                // Links section
                if (resultTypeFilter == .all || resultTypeFilter == .links) && !searchResults.links.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Links")
                            .font(.appSystem(size: 13, weight: .semibold))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 16)

                        VStack(spacing: 8) {
                            ForEach(searchResults.links, id: \.url) { link in
                                linkRow(link: link)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }

                if searchResults.isEmpty(for: resultTypeFilter) {
                    emptyFilterState
                }
            }
            .padding(.vertical, 16)
            .tabBarBottomPadding()
        }
        .scrollDirectionTracking(feedService: feedService)
    }

    /// Shown when the query matched something, but not in the tab that is open.
    @ViewBuilder
    private var emptyFilterState: some View {
        VStack(spacing: 10) {
            Image(systemName: resultTypeFilter.icon)
                .font(.appSystem(size: 26, weight: .thin))
                .foregroundColor(.secondary.opacity(0.5))

            Text("No \(resultTypeFilter.label.lowercased()) matched \u{201C}\(searchQuery.trimmingCharacters(in: .whitespacesAndNewlines))\u{201D}")
                .font(.appSystem(size: 13, weight: .semibold))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            if !searchResults.isEmpty {
                Text("Other tabs have results.")
                    .font(.appSystem(size: 12))
                    .foregroundColor(.secondary.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 24)
    }

    @ViewBuilder
    private func userRow(pubkey: String, profile: FeedProfile) -> some View {
        Button(action: { showingProfile = pubkey }) {
            HStack(spacing: 12) {
                AvatarView(url: profile.pictureURL, pubkey: pubkey, size: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.bestName)
                        .font(.appSystem(size: 13, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    Text(pubkey.prefix(16) + "...")
                        .font(.appSystem(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.appSystem(size: 12, weight: .semibold))
                    .foregroundColor(.secondary.opacity(0.5))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.secondary.opacity(0.05))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func hashtagRow(hashtag: String) -> some View {
        Button(action: {
            // Opens the hashtag's own feed: posts tagged with it, not a word search.
            if let url = HashtagLink.url(for: hashtag) { openURL(url) }
        }) {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("#\(hashtag)")
                    .font(.appSystem(size: 13, weight: .semibold))
                    .foregroundColor(.havenPurple)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.appSystem(size: 12, weight: .semibold))
                .foregroundColor(.secondary.opacity(0.5))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(8)
        .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func linkRow(link: SearchLink) -> some View {
        // A link result looks tappable (purple title, boxed row) and was inert on both
        // platforms. Rows whose URL doesn't parse stay inert rather than pretending.
        conditionalLink(url: URL(string: link.url)) {
        VStack(alignment: .leading, spacing: 4) {
            Text(link.title)
                .font(.appSystem(size: 13, weight: .semibold))
                .foregroundColor(.havenPurple)
                .lineLimit(1)

            Text(link.url)
                .font(.appSystem(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(8)
        .contentShape(Rectangle())
        }
    }

    @ViewBuilder
    private func conditionalLink<Content: View>(url: URL?, @ViewBuilder content: () -> Content) -> some View {
        if let url {
            Link(destination: url) { content() }
                .buttonStyle(.plain)
        } else {
            content()
        }
    }

    private func decodeNostrNoteId(_ query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let result = Bech32.decode(trimmed) else { return nil }
        if result.hrp == "note" {
            return result.data.count == 32 ? result.hexString : nil
        } else if result.hrp == "nevent" {
            var offset = 0
            let data = result.data
            while offset + 1 < data.count {
                let type = data[offset]
                let length = Int(data[offset + 1])
                offset += 2
                guard offset + length <= data.count else { break }
                if type == 0 && length == 32 {
                    return data[offset..<(offset + length)].map { String(format: "%02x", $0) }.joined()
                }
                offset += length
            }
        }
        return nil
    }

    #if os(macOS)
    @ViewBuilder
    private func modeChip(_ mode: SearchMode) -> some View {
        Button(action: {
            guard searchMode != mode else { return }
            searchMode = mode
            rerunSearch()
        }) {
            HStack(spacing: 4) {
                Image(systemName: mode.icon)
                    .font(.appSystem(size: 10, weight: .semibold))
                Text(mode.label)
                    .font(.appSystem(size: 12, weight: .semibold))
            }
            .foregroundColor(searchMode == mode ? .white : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(searchMode == mode ? Color.havenPurple : Color.secondary.opacity(0.12))
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }
    #endif

    /// Re-run the current query, e.g. after switching between relay/global modes.
    private func rerunSearch() {
        nostrService.cancelGlobalSearch()
        nostrService.cancelLocalRelaySearch()
        globalSources = []
        globalFinished = true
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = .empty
            isSearching = false
            return
        }
        performSearch(query: searchQuery)
    }

    /// Runs the search for whatever is in the field right now, cancelling the debounce
    /// task so Return doesn't race a second search behind it.
    private func searchNow() {
        searchDebounceTask?.cancel()
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        performSearch(query: searchQuery)
        saveRecentSearch(searchQuery)
    }

    private func clearSearch() {
        searchDebounceTask?.cancel()
        searchQuery = ""
        resultTypeFilter = .all
        searchResults = .empty
        pendingDirectNoteId = nil
        isSearching = false
        globalSources = []
        globalFinished = true
        nostrService.cancelGlobalSearch()
        nostrService.cancelLocalRelaySearch()
    }

    private func performSearch(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // A new query supersedes whatever Global search was streaming.
        nostrService.cancelGlobalSearch()
        globalSources = []
        globalFinished = true
        guard !trimmed.isEmpty else {
            searchResults = .empty
            pendingDirectNoteId = nil
            return
        }

        let lower = trimmed.lowercased()
        if lower.hasPrefix("note1") || lower.hasPrefix("nevent1") {
            if let eventId = decodeNostrNoteId(trimmed) {
                if let note = feedService.findNote(id: eventId) {
                    openNote(note)
                } else {
                    pendingDirectNoteId = eventId
                    isSearching = true
                    searchResults = .empty
                    feedService.fetchMissingNote(id: eventId)
                }
            }
            return
        }

        // Decode npub to hex pubkey for direct profile lookup
        if lower.hasPrefix("npub1"),
           let decoded = Bech32.decode(trimmed),
           decoded.hrp == "npub" {
            let hexKey = decoded.hexString
            var results = SearchResults()
            if let profile = nostrService.profiles[hexKey] {
                results.users[hexKey] = profile
            } else {
                results.users[hexKey] = FeedProfile(pubkey: hexKey)
            }
            searchResults = results
            isSearching = false
            pendingDirectNoteId = nil
            return
        }

        pendingDirectNoteId = nil

        // Require at least 2 characters for general search
        let trimmedQuery = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard trimmedQuery.count >= 2 else {
            searchResults = .empty
            isSearching = false
            return
        }

        // Global search: this device's store, the Mac relay and the NIP-50
        // search relays at once, streamed as each answers.
        if searchMode == .global {
            isSearching = true
            globalFinished = false
            let requestedQuery = trimmed
            globalSearchLifetime.session = nostrService.startGlobalSearch(query: trimmed,
                                           deviceRelay: feedService.localRelayURL,
                                           follows: feedService.followedPubkeys) { snapshot in
                // Ignore stale updates (user changed query or switched mode).
                guard self.searchMode == .global,
                      self.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == requestedQuery else { return }

                var results = SearchResults()
                for profile in snapshot.profiles {
                    results.users[profile.pubkey] = profile
                }
                results.userOrder = snapshot.profiles.map(\.pubkey)
                // Already ranked own → follows → everyone, newest first in each.
                results.notes = Array(snapshot.notes.prefix(100))

                var foundHashtags = Set<String>()
                for note in snapshot.notes {
                    for tag in self.extractHashtags(from: note.content) where tag.lowercased().contains(trimmedQuery) {
                        foundHashtags.insert(tag)
                    }
                }
                results.hashtags = Array(foundHashtags).sorted()

                results.links = self.extractURLs(from: results.notes)

                self.searchResults = results
                self.globalSources = snapshot.sources
                self.globalFinished = snapshot.isFinished
                self.isSearching = false
            }
            return
        }

        // Relay search: query the local relay's full stored dataset directly,
        // not just whatever the feed subscription has already loaded.
        isSearching = true

        guard let relayURL = feedService.localRelayURL else {
            // Relay not up yet (e.g. still booting) — fall back to whatever's
            // already in memory rather than showing nothing.
            performInMemoryRelaySearch(trimmedQuery: trimmedQuery)
            return
        }

        let requestedQuery = trimmed
        nostrService.localRelaySearch(query: trimmed, relayURL: relayURL) { localResults in
            // Ignore stale completions (user changed query or switched mode).
            guard self.searchMode == .relay,
                  self.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == requestedQuery else { return }

            var results = SearchResults()
            for profile in localResults.profiles {
                results.users[profile.pubkey] = profile
            }
            results.notes = Array(localResults.notes.prefix(20))

            var foundHashtags = Set<String>()
            for note in localResults.notes {
                for tag in self.extractHashtags(from: note.content) where tag.lowercased().contains(trimmedQuery) {
                    foundHashtags.insert(tag)
                }
            }
            results.hashtags = Array(foundHashtags).sorted()

            // Links are what the matching notes link to, so a note that matches
            // on its text contributes its links even when the query is nowhere
            // in the URL (Logen, 2026-09-09).
            results.links = self.extractURLs(from: localResults.notes)

            self.searchResults = results
            self.isSearching = false
        }
    }

    /// Fallback used only when the local relay isn't reachable yet: filters
    /// whatever's already loaded into the live feed/profile cache.
    private func performInMemoryRelaySearch(trimmedQuery: String) {
        let localProfiles = nostrService.profiles
        let localNotes = feedService.notes

        // Same matching rules as the relay walk, so the fallback cannot drift
        // away from the real path.
        guard let matcher = LocalSearchMatcher(query: trimmedQuery) else {
            searchResults = .empty
            isSearching = false
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            var results = SearchResults()

            for (pubkey, profile) in localProfiles {
                if matcher.matchesProfile(displayName: profile.displayName,
                                          name: profile.name,
                                          about: profile.about,
                                          nip05: profile.nip05,
                                          pubkey: pubkey) {
                    results.users[pubkey] = profile
                }
            }

            let relevantNotes = localNotes
                .filter { matcher.matchesNote(content: $0.content) }
                .sorted { $0.createdAt > $1.createdAt }
            results.notes = relevantNotes.prefix(20).map { $0 }

            var foundHashtags = Set<String>()
            for note in relevantNotes {
                let hashtags = extractHashtags(from: note.content)
                for tag in hashtags {
                    if tag.lowercased().contains(trimmedQuery) {
                        foundHashtags.insert(tag)
                    }
                }
            }
            results.hashtags = Array(foundHashtags).sorted()

            results.links = extractURLs(from: relevantNotes)

            DispatchQueue.main.async {
                self.searchResults = results
                self.isSearching = false
            }
        }
    }

    private func extractHashtags(from text: String) -> [String] {
        let pattern = "#\\w+"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        return matches.compactMap {
            guard let range = Range($0.range, in: text) else { return nil }
            return String(text[range]).dropFirst().lowercased()
        }
    }

    /// Links found in the notes that matched. The list is keyed by URL in the
    /// UI, so the same URL is kept once — two notes sharing a link used to be
    /// two rows with the same SwiftUI identity.
    private func extractURLs(from notes: [FeedNote]) -> [SearchLink] {
        var links: [SearchLink] = []
        var seen = Set<String>()
        let urlPattern = "https?://[^\\s]+"

        guard let regex = try? NSRegularExpression(pattern: urlPattern) else { return [] }

        for note in notes {
            let matches = regex.matches(in: note.content, range: NSRange(note.content.startIndex..., in: note.content))
            for match in matches {
                guard let range = Range(match.range, in: note.content) else { continue }
                let url = String(note.content[range])
                guard seen.insert(url).inserted else { continue }
                links.append(SearchLink(url: url, title: url.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: ""), noteId: note.id))
            }
        }

        return links
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

// MARK: - Hashtag feeds

/// `nostrvault://hashtag/<tag>`: what a #hashtag in a post links to.
enum HashtagLink {
    static func url(for tag: String) -> URL? {
        let clean = tag.trimmingCharacters(in: CharacterSet(charactersIn: "#")).lowercased()
        guard !clean.isEmpty,
              let encoded = clean.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: "nostrvault://hashtag/\(encoded)")
    }

    static func tag(from url: URL) -> String? {
        guard url.scheme == "nostrvault", url.host == "hashtag" else { return nil }
        let tag = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).removingPercentEncoding ?? ""
        return tag.isEmpty ? nil : tag.lowercased()
    }
}

extension View {
    /// Opens a hashtag feed, as a sheet from this view, when a #hashtag link
    /// below it is tapped. Put it on each screen that can present (the root,
    /// a profile, a thread, search): the nearest one handles the tap.
    func hashtagLinks() -> some View {
        modifier(HashtagLinkHandling())
    }
}

private struct HashtagLinkHandling: ViewModifier {
    @State private var shown: IdentifiableString?

    func body(content: Content) -> some View {
        content
            .environment(\.openURL, OpenURLAction { url in
                if let tag = HashtagLink.tag(from: url) {
                    shown = IdentifiableString(id: tag)
                    return .handled
                }
                return .systemAction
            })
            .sheet(item: $shown) { item in
                HashtagFeedView(tag: item.id)
                    .environmentObject(NostrService.shared)
                    .environmentObject(ConfigService.shared)
                    #if os(macOS)
                    .frame(minWidth: 520, minHeight: 560)
                    #endif
            }
    }
}

/// Posts tagged with one hashtag (`#t`), newest first, live: the subscription
/// stays open so new posts arrive while the screen is up. Two groups: the
/// people you follow, then everyone else the shield lets through (your Web of
/// Trust, or everyone). Reaching the end of a group loads its next older page.
@MainActor
final class HashtagFeedModel: ObservableObject {
    /// The hashtags being shown. One for the sheet; the Hashtags feed swaps them.
    private(set) var tags: [String]
    @Published private(set) var fromFollows: [FeedNote] = []
    @Published private(set) var fromOthers: [FeedNote] = []
    @Published private(set) var isLoading = true
    /// The group whose older page is on its way, for the spinner under it.
    @Published private(set) var loadingOlder: Section?

    enum Section { case follows, others }

    private var clients: [WebSocketClient] = []
    private var cancellables = Set<AnyCancellable>()
    private var seen = Set<String>()
    private var follows = Set<String>()
    /// What the posts on hand were loaded for; see `start(follows:trust:)`.
    private var shownTags: [String] = []
    private var shownTrust: Set<String>?
    private let queue = DispatchQueue(label: "com.haven.hashtag-feed")
    private var generation = 0
    /// What `start` asked for, kept so an older page asks the same of each group.
    private var followsFilters: [[String: Any]] = []
    private var othersFilters: [[String: Any]] = []
    private var wantedTags = Set<String>()
    private var wantedAuthors: Set<String>?
    private var exhausted = Set<Section>()
    private var pageClients: [WebSocketClient] = []
    private var pageCancellables = Set<AnyCancellable>()
    private var page = 0
    /// Fill your feed: no web of trust yet, so the open list is screened
    /// (`TopicFeedFilter`). Every post lands in `pool`; `fromOthers` is what
    /// passes. Follow counts come from each author's kind 3.
    private(set) var screening = false
    private var pool: [FeedNote] = []
    private var followCounts: [String: Int] = [:]
    private var lookingUp = Set<String>()
    private var rescreenQueued = false
    private var lookupClients: [WebSocketClient] = []
    private var lookupCancellables = Set<AnyCancellable>()
    /// Who else liked, replied to, reposted or zapped each shown post.
    /// Posts people responded to go first (`TopicFeedFilter.ordered`).
    private var responders: [String: Set<String>] = [:]
    private var askedResponders = Set<String>()
    private var pendingResponders: [String] = []
    private var respondersQueued = false

    init(tag: String) { self.tags = [tag] }
    init(tags: [String]) { self.tags = tags }

    /// Same as `start(follows:trust:)` for a new set of hashtags.
    func start(tags: [String], follows: Set<String>, trust: Set<String>?, screen: Bool = false) {
        self.tags = tags
        start(follows: follows, trust: trust, screen: screen)
    }

    /// `follows` fill the top group. `trust` is who else may show: nil is
    /// everyone, empty is nobody (no Web of Trust yet fails closed, like Global).
    /// Everyone is one list by time: with follows on top, a busy follow list
    /// buried everyone else and the shield seemed to do nothing.
    func start(follows: Set<String>, trust: Set<String>?, screen: Bool = false) {
        stop()
        generation += 1
        let gen = generation
        if screen != screening {
            screening = screen
            pool = []
            fromOthers = []
            seen = []
        }
        // Same feed as last time (back from a note): keep the posts so the
        // list, and the scroll position on it, survive; the reopened
        // subscription only adds what is new.
        let resuming = tags == shownTags && follows == self.follows && trust == shownTrust
            && !(fromFollows.isEmpty && fromOthers.isEmpty)
        shownTags = tags
        shownTrust = trust
        if !resuming {
            fromFollows = []
            fromOthers = []
            pool = []
            seen = []
            isLoading = true
        }
        self.follows = follows
        // Filters are rebuilt below; a resumed list keeps what it learned about its end.
        followsFilters = []
        othersFilters = []
        if !resuming { exhausted = [] }

        // NIP-24 says t tags are lowercase; some clients keep the typed case.
        // Capped so the REQ stays under relay message limits.
        let wantedTags = Set(tags.prefix(Self.maxTags).flatMap { [$0, $0.lowercased()] })
        guard !wantedTags.isEmpty else {
            isLoading = false
            return
        }
        let base: [String: Any] = [
            "kinds": [1],
            "#t": Array(wantedTags).sorted(),
            "limit": tags.count > 1 ? 200 : 100,
        ]
        // Follows asked by name, so a busy tag cannot push them out of the page;
        // past the cap, the open filter finds them. Capped so the REQ stays
        // under relay message limits.
        if !follows.isEmpty {
            var byFollows = base
            byFollows["authors"] = Array(follows.sorted().prefix(FeedService.trustedAuthorsCap))
            followsFilters = [byFollows]
        }
        if let trust {
            let others = trust.subtracting(follows)
            if !others.isEmpty {
                othersFilters = FeedService.trustScopedFilters(base, trust: others)
            } else if follows.count > FeedService.trustedAuthorsCap {
                othersFilters = [base]
            }
        } else {
            othersFilters = [base]
        }
        let filters = followsFilters + othersFilters
        guard !filters.isEmpty else {
            isLoading = false
            return
        }
        let wantedAuthors = trust.map { $0.union(follows) }
        self.wantedTags = wantedTags
        self.wantedAuthors = wantedAuthors

        let subId = "hashtag-\(UUID().uuidString.prefix(8))"
        let message: [Any] = ["REQ", subId] + filters
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let req = String(data: data, encoding: .utf8) else { return }

        let relays = ConfigService.shared.config.activeFeedRelays.compactMap(URL.init(string:))
        let blocked = ConfigService.shared.activeAccountBlockedHexPubkeys
        for relay in relays {
            let client = WebSocketClient()
            client.isTemporary = true
            clients.append(client)
            var sent = false
            client.$connectionState
                .sink { [weak client] state in
                    guard state == .connected, !sent, let client else { return }
                    sent = true
                    client.send(text: req)
                }
                .store(in: &cancellables)
            client.messageSubject
                .receive(on: queue)
                .compactMap { message -> FeedNote?? in
                    Self.parse(message, subId: subId, blocked: blocked, tags: wantedTags, authors: wantedAuthors)
                }
                .receive(on: DispatchQueue.main)
                .sink { [weak self] parsed in
                    guard let self, self.generation == gen else { return }
                    switch parsed {
                    case .some(let note?): self.insert(note)
                    case .some(nil): self.isLoading = false   // EOSE from a relay
                    case .none: break
                    }
                }
                .store(in: &cancellables)
            client.connect(url: relay)
        }
        // Never spin forever if every relay is slow or down.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.generation == gen else { return }
            self.isLoading = false
        }
    }

    static let maxTags = 100

    func stop() {
        clients.forEach { $0.disconnect() }
        clients = []
        cancellables.removeAll()
        lookupClients.forEach { $0.disconnect() }
        lookupClients = []
        lookupCancellables.removeAll()
        lookingUp = []
        askedResponders.subtract(askedResponders.filter { responders[$0] == nil })
        stopPage()
    }

    private func stopPage() {
        pageClients.forEach { $0.disconnect() }
        pageClients = []
        pageCancellables.removeAll()
        loadingOlder = nil
    }

    /// Call as each row shows. Near the end of its group, loads that group's
    /// next older page. Older posts only ever join the group being read, at
    /// its end, so nothing above the reader moves: an older post from someone
    /// you follow, found while paging the second group, waits for the first
    /// group's own page.
    func rowAppeared(_ note: FeedNote, in section: Section) {
        let list = section == .follows ? fromFollows : fromOthers
        guard let index = list.lastIndex(where: { $0.id == note.id }),
              index >= list.count - Self.pageAhead else { return }
        loadOlder(section)
    }

    /// The last card of a group showed (Threaded layout, where rows are
    /// conversations rather than single posts).
    func reachedEnd(of section: Section) {
        loadOlder(section)
    }

    private func loadOlder(_ section: Section) {
        // Screened, the oldest post asked for is in the pool, not the list.
        let list = section == .follows ? fromFollows : (screening ? pool : fromOthers)
        let base = section == .follows ? followsFilters : othersFilters
        guard loadingOlder == nil, !exhausted.contains(section),
              let oldest = list.last, !base.isEmpty else { return }
        // Inclusive, so posts sharing the oldest second are not skipped; seen drops repeats.
        let until = Int(oldest.createdAt.timeIntervalSince1970)
        let filters = base.map { filter -> [String: Any] in
            var paged = filter
            paged["until"] = until
            paged["limit"] = Self.pageSize
            return paged
        }
        let subId = "hashtag-older-\(UUID().uuidString.prefix(8))"
        let message: [Any] = ["REQ", subId] + filters
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let req = String(data: data, encoding: .utf8) else { return }

        let gen = generation
        page += 1
        let thisPage = page
        loadingOlder = section
        var added = 0
        var pending = Set<ObjectIdentifier>()
        let finish: () -> Void = { [weak self] in
            guard let self, self.generation == gen, self.page == thisPage, self.loadingOlder != nil else { return }
            if added == 0 { self.exhausted.insert(section) }
            self.stopPage()
        }
        let relays = ConfigService.shared.config.activeFeedRelays.compactMap(URL.init(string:))
        let blocked = ConfigService.shared.activeAccountBlockedHexPubkeys
        let wantedTags = wantedTags
        let wantedAuthors = wantedAuthors
        for relay in relays {
            let client = WebSocketClient()
            client.isTemporary = true
            pageClients.append(client)
            pending.insert(ObjectIdentifier(client))
            var sent = false
            client.$connectionState
                .sink { [weak client] state in
                    guard state == .connected, !sent, let client else { return }
                    sent = true
                    client.send(text: req)
                }
                .store(in: &pageCancellables)
            client.messageSubject
                .receive(on: queue)
                .compactMap { message -> FeedNote?? in
                    Self.parse(message, subId: subId, blocked: blocked, tags: wantedTags, authors: wantedAuthors)
                }
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak client] parsed in
                    guard let self, self.generation == gen, self.page == thisPage else { return }
                    switch parsed {
                    case .some(let note?):
                        if self.insertOlder(note, into: section) { added += 1 }
                    case .some(nil):
                        if let client { pending.remove(ObjectIdentifier(client)) }
                        if pending.isEmpty { finish() }
                    case .none: break
                    }
                }
                .store(in: &pageCancellables)
            client.connect(url: relay)
        }
        if relays.isEmpty { finish() }
        // A relay that never answers must not hold the next page forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: finish)
    }

    /// An older page's post, kept only if it belongs to the group being paged.
    private func insertOlder(_ note: FeedNote, into section: Section) -> Bool {
        // Same split as `insert`: with the shield off there is one list.
        let home: Section = shownTrust != nil && follows.contains(note.pubkey) ? .follows : .others
        guard home == section,
              seen.insert(note.id).inserted else { return false }
        if section == .others && screening {
            Self.insert(note, into: &pool)
            queueRescreen()
            return true
        }
        if section == .follows {
            Self.insert(note, into: &fromFollows)
        } else {
            Self.insert(note, into: &fromOthers)
        }
        return true
    }

    private static let pageSize = 100
    /// How many rows before a group's end its next page starts loading.
    private static let pageAhead = 5
    /// Per group, so a long read stays bounded. Live posts arrive at the top,
    /// so trimming drops the oldest, far below the reader.
    private static let maxNotes = 1500

    private func insert(_ note: FeedNote) {
        guard seen.insert(note.id).inserted else { return }
        if shownTrust != nil, follows.contains(note.pubkey) {
            Self.insert(note, into: &fromFollows)
        } else if screening {
            Self.insert(note, into: &pool)
            queueRescreen()
        } else {
            Self.insert(note, into: &fromOthers)
        }
        isLoading = false
    }

    // MARK: Screening (Fill your feed)

    /// One pass per run-loop turn, however many posts arrived in it.
    private func queueRescreen() {
        guard !rescreenQueued else { return }
        rescreenQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.rescreenQueued = false
            self.lookUpFollowCounts()
            self.rescreen()
        }
    }

    private func rescreen() {
        let posts = pool.map { TopicFeedFilter.Post(id: $0.id, pubkey: $0.pubkey, content: $0.content, tags: $0.tags) }
        let shownIds = TopicFeedFilter.shown(posts, followCounts: followCounts)
        lookUpResponders(shownIds)
        let byId = Dictionary(pool.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let counts = responders.mapValues(\.count)
        let next = TopicFeedFilter.ordered(shownIds, responders: counts).compactMap { byId[$0] }
        if next.map(\.id) != fromOthers.map(\.id) { fromOthers = next }
    }

    /// Replies, reposts, reactions and zaps on the shown posts, counted by
    /// distinct person (the author's own don't count).
    private func lookUpResponders(_ ids: [String]) {
        let fresh = ids.filter { !askedResponders.contains($0) }
        guard !fresh.isEmpty else { return }
        askedResponders.formUnion(fresh)
        pendingResponders.append(contentsOf: fresh)
        // Posts arrive in a stream: ask once a second, not once per post.
        guard !respondersQueued else { return }
        respondersQueued = true
        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.respondersQueued = false
            let missing = self.pendingResponders
            self.pendingResponders = []
            guard self.generation == gen else {
                self.askedResponders.subtract(missing)
                return
            }
            self.askResponders(missing)
        }
    }

    private func askResponders(_ missing: [String]) {
        let authors = Dictionary(pool.map { ($0.id, $0.pubkey) }, uniquingKeysWith: { first, _ in first })
        for batch in missing.chunked(into: 150) {
            let wanted = Set(batch)
            var found: [String: Set<String>] = [:]
            oneShotQuery(["kinds": [1, 6, 7, 9735], "#e": batch, "limit": 2000], onEvent: { ev in
                guard let pubkey = ev["pubkey"] as? String, let tags = ev["tags"] as? [[String]] else { return }
                for tag in tags where tag.count >= 2 && tag[0] == "e" && wanted.contains(tag[1]) {
                    if authors[tag[1]] != pubkey { found[tag[1], default: []].insert(pubkey) }
                }
            }, finish: { [weak self] in
                guard let self else { return }
                for id in batch { self.responders[id, default: []].formUnion(found[id] ?? []) }
                self.rescreen()
            })
        }
    }

    /// One REQ to every feed relay; `finish` runs once, when all have
    /// answered or after 6s, and only if the feed hasn't restarted since.
    private func oneShotQuery(_ filter: [String: Any], onEvent: @escaping ([String: Any]) -> Void,
                              finish: @escaping () -> Void) {
        let gen = generation
        let subId = "q-\(UUID().uuidString.prefix(8))"
        guard let data = try? JSONSerialization.data(withJSONObject: ["REQ", subId, filter] as [Any]),
              let req = String(data: data, encoding: .utf8) else { return }
        let relays = ConfigService.shared.config.activeFeedRelays.compactMap(URL.init(string:))
        var answered = 0
        var finished = false
        let finishOnce = { [weak self] in
            guard !finished else { return }
            finished = true
            guard let self, self.generation == gen else { return }
            finish()
        }
        for relay in relays {
            let client = WebSocketClient()
            client.isTemporary = true
            lookupClients.append(client)
            var sent = false
            client.$connectionState
                .sink { [weak client] state in
                    guard state == .connected, !sent, let client else { return }
                    sent = true
                    client.send(text: req)
                }
                .store(in: &lookupCancellables)
            client.messageSubject
                .receive(on: DispatchQueue.main)
                .sink { message in
                    guard let data = message.data(using: .utf8),
                          let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
                          let type = array.first as? String, array.count >= 2,
                          (array[1] as? String) == subId else { return }
                    if type == "EVENT", array.count >= 3, let ev = array[2] as? [String: Any],
                       NostrEventVerifier.isValid(ev) {
                        onEvent(ev)
                    } else if type == "EOSE" || type == "CLOSED" {
                        answered += 1
                        if answered >= relays.count { finishOnce() }
                    }
                }
                .store(in: &lookupCancellables)
            client.connect(url: relay)
        }
        if relays.isEmpty { finishOnce() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { finishOnce() }
    }

    /// Each new author's newest kind 3, counted. Authors no relay has a
    /// follow list for count as 0, which keeps them out: people follow.
    private func lookUpFollowCounts() {
        let missing = Set(pool.map(\.pubkey)).subtracting(followCounts.keys).subtracting(lookingUp)
        guard !missing.isEmpty else { return }
        let gen = generation
        for batch in Array(missing).chunked(into: 100) {
            lookingUp.formUnion(batch)
            let subId = "follows-\(UUID().uuidString.prefix(8))"
            let message: [Any] = ["REQ", subId, ["kinds": [3], "authors": batch]]
            guard let data = try? JSONSerialization.data(withJSONObject: message),
                  let req = String(data: data, encoding: .utf8) else { continue }
            var newest: [String: (Int64, Int)] = [:]
            var answered = 0
            let relays = ConfigService.shared.config.activeFeedRelays.compactMap(URL.init(string:))
            let finish: () -> Void = { [weak self] in
                guard let self, self.generation == gen else { return }
                for author in batch where self.followCounts[author] == nil {
                    self.followCounts[author] = newest[author]?.1 ?? 0
                }
                self.lookingUp.subtract(batch)
                self.rescreen()
            }
            var finished = false
            let finishOnce = { if !finished { finished = true; finish() } }
            for relay in relays {
                let client = WebSocketClient()
                client.isTemporary = true
                lookupClients.append(client)
                var sent = false
                client.$connectionState
                    .sink { [weak client] state in
                        guard state == .connected, !sent, let client else { return }
                        sent = true
                        client.send(text: req)
                    }
                    .store(in: &lookupCancellables)
                client.messageSubject
                    .receive(on: DispatchQueue.main)
                    .sink { message in
                        guard let data = message.data(using: .utf8),
                              let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
                              let type = array.first as? String, array.count >= 2,
                              (array[1] as? String) == subId else { return }
                        if type == "EVENT", array.count >= 3, let ev = array[2] as? [String: Any],
                           let pubkey = ev["pubkey"] as? String, batch.contains(pubkey),
                           let createdAt = ev["created_at"] as? Int64,
                           let tags = ev["tags"] as? [[String]],
                           (ev["kind"] as? Int) == 3, NostrEventVerifier.isValid(ev) {
                            if (newest[pubkey]?.0 ?? 0) < createdAt {
                                newest[pubkey] = (createdAt, tags.filter { $0.first == "p" }.count)
                            }
                        } else if type == "EOSE" || type == "CLOSED" {
                            answered += 1
                            if answered >= relays.count { finishOnce() }
                        }
                    }
                    .store(in: &lookupCancellables)
                client.connect(url: relay)
            }
            if relays.isEmpty { finishOnce() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { finishOnce() }
        }
    }

    private static func insert(_ note: FeedNote, into list: inout [FeedNote]) {
        let index = list.firstIndex { $0.createdAt < note.createdAt } ?? list.endIndex
        list.insert(note, at: index)
        if list.count > maxNotes { list.removeLast(list.count - maxNotes) }
    }

    /// `.some(note)` for a usable event, `.some(nil)` for EOSE, nil otherwise.
    /// Runs off the main thread: every event's signature is checked, since a
    /// relay can send anything under any author.
    /// Only what was asked for: a relay can send validly signed posts that
    /// lack the tag, or come from people outside the requested authors.
    nonisolated private static func parse(_ message: String, subId: String, blocked: Set<String>,
                                          tags wanted: Set<String>, authors: Set<String>?) -> FeedNote?? {
        guard let data = message.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let type = array.first as? String,
              array.count >= 2, (array[1] as? String) == subId else { return nil }
        if type == "EOSE" { return .some(nil) }
        guard type == "EVENT", array.count >= 3,
              let ev = array[2] as? [String: Any],
              let id = ev["id"] as? String,
              let pubkey = ev["pubkey"] as? String,
              let content = ev["content"] as? String,
              let createdAt = ev["created_at"] as? Int64,
              let kind = ev["kind"] as? Int, kind == 1,
              let tags = ev["tags"] as? [[String]],
              !blocked.contains(pubkey),
              authors.map({ $0.contains(pubkey) }) ?? true,
              tags.contains(where: { $0.count >= 2 && $0[0] == "t" && wanted.contains($0[1].lowercased()) }),
              !FeedNote.isNoiseOrSpam(content: content, tags: tags),
              NostrEventVerifier.isValid(ev) else { return nil }
        return .some(FeedNote(id: id, pubkey: pubkey, content: content,
                              createdAt: Date(timeIntervalSince1970: TimeInterval(createdAt)),
                              tags: tags, kind: kind))
    }
}

/// A hashtag's posts: people you follow first, then the rest of your network.
/// Everyone sits behind the same app-wide shield and warning as Global.
struct HashtagFeedView: View {
    let tag: String
    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var configService: ConfigService
    @ObservedObject private var feedService = FeedService.shared
    @ObservedObject private var interests = InterestListService.shared
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: HashtagFeedModel
    @State private var showingEveryoneWarning = false
    @State private var followSaving = false
    @State private var showingFollowFailed = false
    @State private var showingProfile: IdentifiableString?
    @State private var showingNote: FeedNote?
    @State private var showingMediaUrl: IdentifiableURL?
    @Namespace private var mediaZoom

    init(tag: String) {
        self.tag = tag
        _model = StateObject(wrappedValue: HashtagFeedModel(tag: tag))
    }

    private var everyone: Bool { configService.config.globalShowsEveryone }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 12) {
                    header
                    if model.fromFollows.isEmpty && model.fromOthers.isEmpty {
                        emptyState
                    }
                    if !model.fromFollows.isEmpty {
                        sectionHeader("From people you follow")
                        ForEach(model.fromFollows) { note in
                            row(note).onAppear { model.rowAppeared(note, in: .follows) }
                        }
                        if model.loadingOlder == .follows { olderSpinner }
                    }
                    if !model.fromOthers.isEmpty {
                        if !everyone { sectionHeader("More from your network") }
                        ForEach(model.fromOthers) { note in
                            row(note).onAppear { model.rowAppeared(note, in: .others) }
                        }
                        if model.loadingOlder == .others { olderSpinner }
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .environment(\.feedActions, .make(feedService: feedService, nostrService: nostrService))
            .navigationTitle("")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        if everyone {
                            configService.config.globalShowsEveryone = false
                            configService.save()
                        } else {
                            showingEveryoneWarning = true
                        }
                    } label: {
                        Image(systemName: everyone ? "shield.slash.fill" : "checkmark.shield.fill")
                            .foregroundColor(everyone ? .orange : .havenPurple)
                    }
                    .accessibilityLabel(everyone ? "Everyone" : "Web of Trust")
                    .help(everyone ? "Everyone: unfiltered posts. Click for your Web of Trust" : "Web of Trust: people you follow and the people they follow. Click for everyone")
                }
            }
        }
        .hashtagLinks()
        .task {
            interests.refreshIfNeeded()
            restart()
        }
        // The follow list and the trust graph can arrive after the sheet opens.
        .onChange(of: feedService.followedPubkeys.count) { _, _ in restart() }
        .onChange(of: feedService.wotPubkeys.count) { _, _ in restart() }
        .onChange(of: everyone) { _, _ in restart() }
        .onDisappear { model.stop() }
        .alert(String(localized: "feed.alert.sensitiveContent.title"), isPresented: $showingEveryoneWarning) {
            Button(String(localized: "feed.alert.sensitiveContent.proceed"), role: .destructive) {
                configService.config.globalShowsEveryone = true
                configService.save()
            }
            Button(String(localized: "feed.alert.sensitiveContent.cancel"), role: .cancel) {}
        } message: {
            Text("Everyone shows posts from people outside your Web of Trust, unfiltered. Expect spam and sensitive content.")
        }
        .alert("Couldn't save", isPresented: $showingFollowFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Your relays didn't answer, so your hashtag list wasn't changed. Try again in a moment.")
        }
        .sheet(item: $showingProfile) { profile in
            ProfileView(pubkey: profile.id, onDismiss: { showingProfile = nil })
                .environmentObject(nostrService)
                .environmentObject(configService)
        }
        .sheet(item: $showingNote) { note in
            NavigationStack {
                NoteDetailView(note: note)
                    .navigationDestination(for: FeedNote.self) { NoteDetailView(note: $0) }
            }
            .environmentObject(nostrService)
            .environmentObject(configService)
        }
        .mediaViewer(item: $showingMediaUrl, namespace: mediaZoom)
    }

    /// Your own posts count with your follows: you just tagged it, you want to see it.
    private func restart() {
        var follows = Set(feedService.followedPubkeys)
        if !configService.activeAccountHexPubkey.isEmpty { follows.insert(configService.activeAccountHexPubkey) }
        model.start(follows: follows, trust: feedService.globalTrustSet())
    }

    private var isFollowingTag: Bool { interests.isFollowing(tag) }

    /// Big #tag with the Follow button. Followed tags are your interest list
    /// (kind 10015), the same list other Nostr apps read.
    private var header: some View {
        HStack(spacing: 12) {
            Text("#\(tag)")
                .font(.appTitle2)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Button(action: toggleFollow) {
                HStack(spacing: 6) {
                    Image(systemName: isFollowingTag ? "checkmark" : "plus")
                        .font(.appSystem(size: 12, weight: .semibold))
                    Text(isFollowingTag ? "Following" : "Follow")
                        .font(.appSystem(size: 13, weight: .semibold))
                }
                .foregroundColor(isFollowingTag ? .white : .havenPurple)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(isFollowingTag ? Color.havenPurple : Color.havenPurple.opacity(0.12))
                .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .disabled(followSaving || configService.activeAccountHexPubkey.isEmpty)
            .accessibilityLabel(isFollowingTag ? "Unfollow #\(tag)" : "Follow #\(tag)")
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    private func toggleFollow() {
        let follow = !isFollowingTag
        followSaving = true
        Task {
            let ok = await interests.setFollowing(tag, follow)
            followSaving = false
            if !ok { showingFollowFailed = true }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 10) {
            if model.isLoading {
                ProgressView()
            } else {
                Image(systemName: "number").font(.appSystem(size: 28)).foregroundColor(.secondary)
                Text(everyone ? "No posts tagged #\(tag) yet"
                              : "No posts tagged #\(tag) from people you follow or your network yet")
                    .font(.appSubheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                if !everyone {
                    Text("The shield above shows everyone.")
                        .font(.appCaption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.top, 60)
    }

    private var olderSpinner: some View {
        ProgressView()
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.appSubheadline.weight(.semibold))
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 8)
    }

    private func row(_ note: FeedNote) -> some View {
        FeedNoteRow(
            note: note,
            profile: nostrService.profiles[note.pubkey],
            rowData: FeedNoteRowData.resolve(for: note, feedService: feedService, nostrService: nostrService),
            onProfile: { showingProfile = IdentifiableString(id: $0) },
            onMedia: { url, urls in showingMediaUrl = IdentifiableURL(url: url, allURLs: urls) },
            showParent: false
        )
        .contentShape(Rectangle())
        .onTapGesture { showingNote = note }
        .padding(.horizontal, 16)
        .onAppear { nostrService.fetchMissingProfiles(for: [note.pubkey]) }
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
