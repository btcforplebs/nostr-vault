import SwiftUI

// MARK: - SearchView

struct SearchView: View {
    @StateObject private var feedService = FeedService.shared
    @EnvironmentObject var relayManager: RelayProcessManager
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var nostrService: NostrService

    @State private var searchQuery: String = ""
    @State private var resultTypeFilter: ResultTypeFilter = .all
    @State private var searchMode: SearchMode = .relay
    @State private var searchResults: SearchResults = .empty
    @State private var isSearching = false
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var showingNoteDetail: FeedNote?
    @State private var showingProfile: String?
    @State private var showingMediaUrl: IdentifiableURL?
    @State private var pendingDirectNoteId: String?
    @State private var showingCompose = false
    @State private var recentSearches: [String] = UserDefaults.standard.stringArray(forKey: "recentSearches") ?? []
    @State private var cachedTrending: [String] = []
    @State private var cachedSuggested: [(String, FeedProfile)] = []
    @State private var lastDiscoveryRefresh: Date = .distantPast
    #if os(iOS)
    @FocusState private var searchFieldFocused: Bool
    #endif

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
        var notes: [FeedNote] = []
        var links: [SearchLink] = []
        var hashtags: [String] = []

        static let empty = SearchResults()

        var isEmpty: Bool {
            users.isEmpty && notes.isEmpty && links.isEmpty && hashtags.isEmpty
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
                            #if os(iOS)
                            .focused($searchFieldFocused)
                            .submitLabel(.search)
                            .onSubmit { searchFieldFocused = false }
                            #endif
                            .onChange(of: searchQuery) { _, query in
                                searchDebounceTask?.cancel()
                                let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
                                if trimmed.isEmpty {
                                    searchResults = .empty
                                    pendingDirectNoteId = nil
                                    isSearching = false
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
                                searchQuery = ""
                                resultTypeFilter = .all
                                nostrService.cancelGlobalSearch()
                                nostrService.cancelLocalRelaySearch()
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
            if !feedService.feedScrollingDown {
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
                .padding(.trailing, 20)
                .padding(.bottom, 90)
                .hoverEffect(.lift)
                .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .animation(Motion.chrome, value: feedService.feedScrollingDown)
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
        }
        .sheet(item: $showingNoteDetail) { note in
            NavigationStack {
                NoteDetailView(note: note)
                    .navigationDestination(for: FeedNote.self) { detailNote in
                        NoteDetailView(note: detailNote)
                    }
            }
        }
        .sheet(item: $showingMediaUrl) { media in
            FeedMediaPager(urls: media.allURLs, selected: media.url, onDismiss: { showingMediaUrl = nil })
        }
        .onAppear {
            refreshDiscovery(force: true)
        }
        .onReceive(feedService.$notes) { notes in
            // Throttled refresh of the empty-state discovery lists as the feed grows.
            refreshDiscovery()

            guard let noteId = pendingDirectNoteId else { return }
            if let note = notes.first(where: { $0.id == noteId }) {
                pendingDirectNoteId = nil
                isSearching = false
                showingNoteDetail = note
            }
        }
        .onReceive(feedService.$parentNotesCache) { cache in
            guard let noteId = pendingDirectNoteId else { return }
            if let note = cache[noteId] {
                pendingDirectNoteId = nil
                isSearching = false
                showingNoteDetail = note
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
                                        AvatarView(url: profile.pictureURL, pubkey: pubkey)
                                            .frame(width: 34, height: 34)
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
                            ForEach(searchResults.users.sorted(by: { $0.key < $1.key }), id: \.key) { pubkey, profile in
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
                                        showingNoteDetail = note
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
                AvatarView(url: profile.pictureURL, pubkey: pubkey)
                    .frame(width: 40, height: 40)

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
    }

    @ViewBuilder
    private func linkRow(link: SearchLink) -> some View {
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
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = .empty
            isSearching = false
            return
        }
        performSearch(query: searchQuery)
    }

    private func performSearch(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = .empty
            pendingDirectNoteId = nil
            return
        }

        let lower = trimmed.lowercased()
        if lower.hasPrefix("note1") || lower.hasPrefix("nevent1") {
            if let eventId = decodeNostrNoteId(trimmed) {
                if let note = feedService.findNote(id: eventId) {
                    showingNoteDetail = note
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

        // Global (NIP-50) search across external relays.
        if searchMode == .global {
            isSearching = true
            let requestedQuery = trimmed
            nostrService.globalSearch(query: trimmed) { globalResults in
                // Ignore stale completions (user changed query or switched mode).
                guard self.searchMode == .global,
                      self.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == requestedQuery else { return }

                var results = SearchResults()
                for profile in globalResults.profiles {
                    results.users[profile.pubkey] = profile
                }
                results.notes = Array(globalResults.notes.prefix(30))

                var foundHashtags = Set<String>()
                for note in globalResults.notes {
                    for tag in self.extractHashtags(from: note.content) where tag.lowercased().contains(trimmedQuery) {
                        foundHashtags.insert(tag)
                    }
                }
                results.hashtags = Array(foundHashtags).sorted()

                results.links = self.extractURLs(from: globalResults.notes)

                self.searchResults = results
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

