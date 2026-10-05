import SwiftUI

extension VaultView {

    // MARK: - List Content Dispatch

    @ViewBuilder
    var listContent: some View {
        // The reader sits inside each platform's ScrollView, so one copy serves
        // the iOS, wide-mac and compact-mac layouts.
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                Group {
                    if searchScope == .profiles && !committedSearch.isEmpty {
                        profileSearchResults
                    } else if viewMode == .notes {
                        notesList
                    } else if viewMode == .likes {
                        likesList
                    } else if viewMode == .zaps {
                        zapsList
                    } else if viewMode == .followers {
                        followersList
                    }
                }
                .animation(.none, value: viewMode)
                .id("\(viewMode)-\(searchScope)-\(committedSearch.isEmpty)")
            }
            .padding(.vertical, 16)
            .contentShape(Rectangle())
            // onAppear covers a tap that mounted this tab; onReceive, one that
            // arrived while it was already on screen.
            .onAppear { consumeRelayFocus(proxy: proxy) }
            .task(id: followersOwnerHex) { await pollFollowers() }
            .onReceive(NotificationCenter.default.publisher(for: .havenFocusRelayEvent)) { _ in
                consumeRelayFocus(proxy: proxy)
            }
        }
    }

    // MARK: - nostr: links

    /// Opens a `nostr:` link tapped inside note text. One definition for every
    /// list in this tab — the notes list used to be missing `naddr1`, so tapping
    /// a quoted article there fell through to the system and did nothing.
    var nostrLinkAction: OpenURLAction {
        OpenURLAction { url in
            if HashtagLink.tag(from: url) != nil {
                inheritedOpenURL(url)
                return .handled
            }
            guard url.scheme == "nostr" else { return .systemAction }
            let id = url.absoluteString.replacingOccurrences(of: "nostr:", with: "")
            if id.hasPrefix("npub1") || id.hasPrefix("nprofile1") {
                if let pubkey = QuoteReference.profilePubkey(fromBech32: id) {
                    self.showingProfilePubkey = pubkey
                }
                return .handled
            }
            if id.hasPrefix("note1") || id.hasPrefix("nevent1") || id.hasPrefix("naddr1") {
                self.openNote(id)
                return .handled
            }
            return .systemAction
        }
    }

    // MARK: - Notes List

    var notesList: some View {
        let isLoading = nostrService.isFetching || relayManager.isBooting || !notesHasLoadedOnce
        return Group {
            if displayNotes.isEmpty && isLoading {
                VStack(spacing: 32) {
                    VStack(spacing: 16) {
                        ProgressView()
                            .controlSize(.large)
                            .tint(Color.havenPurple)

                        VStack(spacing: 8) {
                            Text(relayManager.isBooting ? relayManager.bootStatusMessage.isEmpty ? "Starting relay..." : relayManager.bootStatusMessage : "Loading notes...")
                                .font(.appSystem(size: 18, weight: .bold, design: .default))
                                .tracking(0.3)
                            Text("This may take a moment")
                                .font(.appSystem(size: 12, weight: .medium, design: .monospaced))
                                .foregroundColor(.secondary.opacity(0.6))
                                .tracking(0.5)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.platformWindowBackground)
            } else if displayNotes.isEmpty {
                VStack(spacing: 24) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.appSystem(size: 48, weight: .thin))
                        .foregroundStyle(
                            LinearGradient(
                                gradient: Gradient(colors: [Color.havenPurple, Color.havenPurpleLight]),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    VStack(spacing: 8) {
                        Text("No notes found")
                            .font(.appSystem(size: 18, weight: .bold, design: .default))
                            .tracking(0.2)

                        Text("Try changing your filter settings")
                            .font(.appSystem(size: 13, weight: .regular, design: .monospaced))
                            .foregroundColor(.secondary)
                            .tracking(0.3)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.platformWindowBackground)
            } else {
                let whitelisted = configService.whitelistedHexPubkeys
                let owner = nostrService.activeHexPubkey
                LazyVStack(spacing: 12) {
                    ForEach(displayNotes) { event in
                        let showEngagement = event.pubkey == owner || whitelisted.contains(event.pubkey)
                        #if os(iOS)
                        NoteNavigationLink(note: FeedNote(
                            id: event.id,
                            pubkey: event.pubkey,
                            content: event.content,
                            createdAt: event.createdAtDate,
                            tags: event.tags,
                            kind: event.kind
                        )) {
                            NoteRow(
                                event: event,
                                layoutMode: rowLayoutMode,
                                reactors: showEngagement ? reactionMap[event.id] : nil,
                                latestReactionDate: showEngagement ? latestReactionDates[event.id] : nil,
                                zappers: showEngagement ? zapMap[event.id] : nil,
                                reposterPubkeys: showEngagement ? repostMap[event.id] : nil,
                                quoterPubkeys: showEngagement ? quoteMap[event.id] : nil
                            )
                            .relayFocusOutline(focusedEventId == event.id)
                            // Likes and Zaps rows carry this same inset; Notes rows
                            // were flush to the pane edges, the one filter that read
                            // differently from the other two.
                            .padding(.horizontal, 16)
                        }
                        .buttonStyle(.plain)
                        #else
                        NoteRow(
                            event: event,
                            layoutMode: rowLayoutMode,
                            reactors: showEngagement ? reactionMap[event.id] : nil,
                            latestReactionDate: showEngagement ? latestReactionDates[event.id] : nil,
                            zappers: showEngagement ? zapMap[event.id] : nil,
                            reposterPubkeys: showEngagement ? repostMap[event.id] : nil,
                            quoterPubkeys: showEngagement ? quoteMap[event.id] : nil
                        )
                        .relayFocusOutline(focusedEventId == event.id)
                        .padding(.horizontal, 16)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            self.openNote(event.id)
                        }
                        #endif
                    }
                }
                .environment(\.openURL, nostrLinkAction)
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Likes List

    var likesList: some View {
        let isFetching = nostrService.isFetching || relayManager.isBooting
        // Keep showing the loading view until we've either populated content
        // (likesHasLoadedOnce) or settled into a confirmed-empty state.
        let showLoading = displayLikedNotes.isEmpty
            && !likesHasLoadedOnce
            && (isFetching || !likesInitialSettled)
        return Group {
            if showLoading {
                VStack(spacing: 32) {
                    VStack(spacing: 16) {
                        ProgressView()
                            .controlSize(.large)
                            .tint(Color.havenPurple)
                        VStack(spacing: 8) {
                            Text("Loading likes...")
                                .font(.appSystem(size: 18, weight: .bold, design: .default))
                                .tracking(0.3)
                            Text("This may take a moment")
                                .font(.appSystem(size: 12, weight: .medium, design: .monospaced))
                                .foregroundColor(.secondary.opacity(0.6))
                                .tracking(0.5)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.platformWindowBackground)
            } else if displayLikedNotes.isEmpty {
                VStack(spacing: 24) {
                    Image(systemName: likesFilter != .myLikes ? "heart.slash" : "heart")
                        .font(.appSystem(size: 48, weight: .thin))
                        .foregroundStyle(
                            LinearGradient(
                                gradient: Gradient(colors: [.red, .pink]),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    VStack(spacing: 8) {
                        Text(likesFilter != .myLikes ? "No reactions yet" : "No liked posts")
                            .font(.appSystem(size: 18, weight: .bold, design: .default))
                            .tracking(0.2)
                        Text(likesFilter != .myLikes ? "Reactions on these notes will appear here" : "Posts you've liked will appear here")
                            .font(.appSystem(size: 13, weight: .regular, design: .monospaced))
                            .foregroundColor(.secondary)
                            .tracking(0.3)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.platformWindowBackground)
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(displayLikedNotes) { event in
                        // Reactions render inside the card's engagement bar, below
                        // the post — same as the Notes filter. They used to sit in a
                        // separate row above the card here, so the same information
                        // appeared on opposite sides of the post depending on which
                        // filter you were looking at.
                        let rowReactors = likesFilter != .myLikes ? reactionMap[event.id] : nil
                        let rowReactionDate = likesFilter != .myLikes ? latestReactionDates[event.id] : nil
                        VStack(alignment: .leading, spacing: 0) {
                            #if os(iOS)
                            NoteNavigationLink(note: FeedNote(
                                id: event.id,
                                pubkey: event.pubkey,
                                content: event.content,
                                createdAt: event.createdAtDate,
                                tags: event.tags,
                                kind: event.kind
                            )) {
                                NoteRow(event: event, truncate: true, layoutMode: rowLayoutMode, reactors: rowReactors, latestReactionDate: rowReactionDate)
                                    .relayFocusOutline(focusedEventId == event.id)
                                    .padding(.horizontal, 16)
                                    .onAppear {
                                        if event.id == displayLikedNotes.last?.id {
                                            loadMoreItems()
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            #else
                            NoteRow(event: event, truncate: true, layoutMode: rowLayoutMode, reactors: rowReactors, latestReactionDate: rowReactionDate)
                                .relayFocusOutline(focusedEventId == event.id)
                                .padding(.horizontal, 16)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    self.openNote(event.id)
                                }
                                .onAppear {
                                    if event.id == displayLikedNotes.last?.id {
                                        loadMoreItems()
                                    }
                                }
                            #endif
                        }
                    }
                }
                .environment(\.openURL, nostrLinkAction)
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Zaps List

    var zapsList: some View {
        // Settle-driven loading: never gate the spinner on isFetching (which is
        // ~always true here while the feed/relay fetches), or the Zaps view spins
        // forever when there are no zaps yet. Show the spinner only until the
        // initial settle completes (bounded ~6s, see updateZapsSettleState).
        let showLoading = displayZappedNotes.isEmpty
            && !zapsHasLoadedOnce
            && !zapsInitialSettled
        return Group {
            if showLoading {
                VStack(spacing: 32) {
                    VStack(spacing: 16) {
                        ProgressView()
                            .controlSize(.large)
                            .tint(Color.havenPurple)
                        VStack(spacing: 8) {
                            Text("Loading zaps...")
                                .font(.appSystem(size: 18, weight: .bold, design: .default))
                                .tracking(0.3)
                            Text("This may take a moment")
                                .font(.appSystem(size: 12, weight: .medium, design: .monospaced))
                                .foregroundColor(.secondary.opacity(0.6))
                                .tracking(0.5)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.platformWindowBackground)
            } else if displayZappedNotes.isEmpty {
                VStack(spacing: 24) {
                    Image(systemName: zapsFilter != .myZaps ? "bolt.slash" : "bolt")
                        .font(.appSystem(size: 48, weight: .thin))
                        .foregroundStyle(
                            LinearGradient(
                                gradient: Gradient(colors: [.orange, .yellow]),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    VStack(spacing: 8) {
                        Text(zapsFilter != .myZaps ? "No zaps yet" : "No zapped posts")
                            .font(.appSystem(size: 18, weight: .bold, design: .default))
                            .tracking(0.2)
                        Text(zapsFilter != .myZaps ? "Zaps on these notes will appear here" : "Posts you've zapped will appear here")
                            .font(.appSystem(size: 13, weight: .regular, design: .monospaced))
                            .foregroundColor(.secondary)
                            .tracking(0.3)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.platformWindowBackground)
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(displayZappedNotes) { event in
                        // Same unification as the Likes filter — zaps belong in the
                        // card's engagement bar under the post, not in a row above it.
                        let rowZappers = zapsFilter != .myZaps ? zapMap[event.id] : nil
                        VStack(alignment: .leading, spacing: 0) {
                            #if os(iOS)
                            NoteNavigationLink(note: FeedNote(
                                id: event.id,
                                pubkey: event.pubkey,
                                content: event.content,
                                createdAt: event.createdAtDate,
                                tags: event.tags,
                                kind: event.kind
                            )) {
                                NoteRow(event: event, truncate: true, layoutMode: rowLayoutMode, zappers: rowZappers)
                                    .relayFocusOutline(focusedEventId == event.id)
                                    .padding(.horizontal, 16)
                                    .onAppear {
                                        if event.id == displayZappedNotes.last?.id {
                                            loadMoreItems()
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            #else
                            NoteRow(event: event, truncate: true, layoutMode: rowLayoutMode, zappers: rowZappers)
                                .relayFocusOutline(focusedEventId == event.id)
                                .padding(.horizontal, 16)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    self.openNote(event.id)
                                }
                                .onAppear {
                                    if event.id == displayZappedNotes.last?.id {
                                        loadMoreItems()
                                    }
                                }
                            #endif
                        }
                    }
                }
                .environment(\.openURL, nostrLinkAction)
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Profile Search Results

    @ViewBuilder
    var profileSearchResults: some View {
        if displayProfileResults.isEmpty {
            VStack(spacing: 24) {
                Image(systemName: "person.2.slash")
                    .font(.appSystem(size: 48, weight: .thin))
                    .foregroundStyle(
                        LinearGradient(
                            gradient: Gradient(colors: [Color.havenPurple, Color.havenPurple.opacity(0.5)]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                VStack(spacing: 8) {
                    Text("No profiles found")
                        .font(.appSystem(size: 18, weight: .bold))
                        .tracking(0.2)
                    Text("Try a different search term")
                        .font(.appSystem(size: 13, weight: .regular, design: .monospaced))
                        .foregroundColor(.secondary)
                        .tracking(0.3)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 80)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(displayProfileResults) { profile in
                    ProfileResultRow(profile: profile)
                        .onTapGesture {
                            showingProfilePubkey = profile.pubkey
                        }
                    Divider()
                        .background(Color(red: 0.2, green: 0.2, blue: 0.25))
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Notification focus

/// Where a tapped notification should land inside the Relay tab.
struct RelayFocusRequest {
    let type: String
    let eventId: String
}

/// Parks a notification's target until the Relay tab can scroll to it. The tab
/// is created lazily, so a tap on a cold launch (or before the tab was ever
/// opened) posts before anything is listening; parking is what lets the tab
/// pick the target up as it mounts.
@MainActor
enum RelayFocus {
    static var pending: RelayFocusRequest?

    static func request(type: String, eventId: String) {
        pending = RelayFocusRequest(type: type, eventId: eventId)
        NotificationCenter.default.post(name: .havenFocusRelayEvent, object: nil)
    }
}

extension VaultView {

    /// Switches to the filter that holds the notification's event, scrolls to
    /// it and outlines it. Falls back to opening the post when it never shows
    /// up in the list (older than the loaded page), so a tap always lands on it.
    func consumeRelayFocus(proxy: ScrollViewProxy) {
        guard let request = RelayFocus.pending else { return }
        RelayFocus.pending = nil

        navigationPath = NavigationPath()
        showingNoteId = nil
        committedSearch = ""
        isSearchActive = false
        switch request.type {
        case "reaction" where !configService.config.zapsOnlyMode:
            viewMode = .likes
            likesFilter = .onMyNotes
        case "zap":
            viewMode = .zaps
            zapsFilter = .onMyNotes
        default:
            viewMode = .notes
            // A reply from outside your network isn't listed under All.
            if let author = nostrService.events.first(where: { $0.id == request.eventId })?.pubkey,
               ContentFilter.isOutside(author: author, owner: nostrService.activeHexPubkey,
                                       whitelist: configService.whitelistedHexPubkeys,
                                       trusted: FeedService.shared.wotPubkeys) {
                contentFilter = .outside
            } else {
                contentFilter = .all
            }
        }

        focusTask?.cancel()
        focusTask = Task { @MainActor in
            // The event can still be arriving from the relay and the display
            // lists rebuild on a debounce, so look for up to ~10 s.
            for _ in 0..<40 {
                if Task.isCancelled { return }
                if let id = focusTargetId(for: request) {
                    try? await Task.sleep(for: .milliseconds(150))
                    withAnimation(Motion.toggle) { proxy.scrollTo(id, anchor: .center) }
                    focusedEventId = id
                    try? await Task.sleep(for: .seconds(3))
                    if focusedEventId == id {
                        withAnimation(.easeOut(duration: 0.6)) { focusedEventId = nil }
                    }
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            if Task.isCancelled { return }
            openNote(focusCandidates(for: request).dropFirst().first ?? request.eventId)
        }
    }

    /// The notification's own event first, then what it points at — a
    /// reaction, zap receipt or repost is listed under the note it targets.
    /// NIP-25 puts the target in the last `e` tag, hence reversed.
    private func focusCandidates(for request: RelayFocusRequest) -> [String] {
        var ids = [request.eventId]
        if let event = nostrService.events.first(where: { $0.id == request.eventId }) {
            ids += event.tags
                .filter { $0.count >= 2 && $0[0] == "e" }
                .map { $0[1] }
                .reversed()
        }
        return ids
    }

    private func focusTargetId(for request: RelayFocusRequest) -> String? {
        let shown: [NostrEvent]
        switch viewMode {
        case .likes: shown = displayLikedNotes
        case .zaps: shown = displayZappedNotes
        default: shown = displayNotes
        }
        let shownIds = Set(shown.map(\.id))
        return focusCandidates(for: request).first(where: shownIds.contains)
    }
}

extension View {
    /// Outlines the row a notification tap landed on. Same radius as `NoteRow`'s card.
    func relayFocusOutline(_ isFocused: Bool) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.havenPurple, lineWidth: 2)
                .opacity(isFocused ? 1 : 0)
                .allowsHitTesting(false)
        )
    }
}
