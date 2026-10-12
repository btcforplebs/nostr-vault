import SwiftUI

extension FeedView {
    // MARK: - Feed List

    /// Articles feed: long-form events from the follow set, already synced to
    /// the device's own relay by the normal feed sync, rendered as cards
    /// instead of as notes.
    @ViewBuilder
    var articleListView: some View {
        LazyVStack(spacing: 14) {
            if feedService.isLoadingFeed && feedService.filteredNotes.isEmpty {
                ForEach(0..<3, id: \.self) { _ in
                    FeedNoteSkeletonRow()
                        .padding(.horizontal, 16)
                }
            }

            if feedService.filteredNotes.isEmpty && !feedService.isLoadingFeed {
                emptyArticlesStateView
            }

            ForEach(feedService.filteredNotes) { note in
                let card = ArticleCardView(
                    note: note,
                    profile: nostrService.profiles[note.pubkey],
                    onAuthorTap: { pubkey in showingProfileKey = IdentifiableString(id: pubkey) }
                )
                .padding(.horizontal, 16)

                #if os(iOS)
                // In the iPad two-pane layout the feed is NOT wrapped in its
                // own NavigationStack — NoteSplitPane owns the detail column —
                // so a NavigationLink here has no stack to push onto and the
                // tap silently does nothing. Route through the selection the
                // same way note rows do.
                if let noteDetailSelection {
                    card
                        .contentShape(Rectangle())
                        .onTapGesture { noteDetailSelection.select(note) }
                } else {
                    NavigationLink(value: ArticleRoute(note: note)) { card }
                        .buttonStyle(.plain)
                }
                #else
                card.onTapGesture { showingArticle = ArticleRoute(note: note) }
                #endif
            }

            if !feedService.filteredNotes.isEmpty {
                Color.clear
                    .frame(height: 1)
                    .onAppear { feedService.loadMore() }
            }
        }
        .padding(.vertical, 16)
    }

    private var emptyArticlesStateView: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.richtext")
                .font(.appSystem(size: 34))
                .foregroundColor(.havenPurple.opacity(0.7))
            Text("No articles yet")
                .font(.appSystem(size: 16, weight: .bold))
            Text(feedService.articlesFeedMode == .following
                 ? "Long-form posts from people you follow show up here. Nothing to read yet."
                 : "Long-form posts from across Nostr show up here. Nothing to read yet.")
                .font(.appSystem(size: 13))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 60)
    }

    /// Recipes feed: long-form events tagged zapcooking / nostrcooking, pulled
    /// live from external relays. Recipe authors are strangers, so these are
    /// deliberately not synced to the owner's own relay — the grid is empty
    /// without a connection, unlike Articles.
    ///
    /// A recipe opens as a sheet rather than a push: the grid appears inside
    /// three different containers (the iPhone navigation stack, the iPad
    /// two-pane layout which owns its own stack, and the macOS window), and a
    /// sheet is the one presentation that behaves the same in all three.
    @ViewBuilder
    var recipeGridView: some View {
        VStack(spacing: 12) {
            if !recipeService.categories.isEmpty {
                RecipeCategoryBar(categories: recipeService.categories, selected: $recipeService.selectedCategory)
            }

            if recipeService.isLoading && recipeService.visibleRecipes.isEmpty {
                ProgressView()
                    .controlSize(.large)
                    .tint(Color.havenPurple)
                    .padding(.vertical, 60)
            } else if recipeService.visibleRecipes.isEmpty {
                emptyRecipesStateView
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    ForEach(recipeService.visibleRecipes) { recipe in
                        let card = RecipeCardView(note: recipe, profile: nostrService.profiles[recipe.pubkey])

                        card
                            .contentShape(Rectangle())
                            .onTapGesture { showingArticle = ArticleRoute(note: recipe) }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.vertical, 16)
        .onAppear { recipeService.loadIfNeeded() }
    }

    private var emptyRecipesStateView: some View {
        VStack(spacing: 10) {
            Image(systemName: recipeService.loadFailed ? "wifi.slash" : "fork.knife")
                .font(.appSystem(size: 34))
                .foregroundColor(.havenPurple.opacity(0.7))
            Text(emptyRecipesTitle)
                .font(.appSystem(size: 16, weight: .bold))
            Text(emptyRecipesMessage)
                .font(.appSystem(size: 13))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            if recipeService.followSetIsEmpty {
                Button("Show Global recipes") { recipeService.setScope(.global) }
                    .buttonStyle(.borderless)
                    .foregroundColor(.havenPurple)
                    .padding(.top, 4)
            } else {
                Button("Try again") { recipeService.refresh() }
                    .buttonStyle(.borderless)
                    .foregroundColor(.havenPurple)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 60)
    }

    private var emptyRecipesTitle: String {
        if recipeService.followSetIsEmpty { return "No recipes from your follows" }
        return recipeService.loadFailed ? "Could not reach any relay" : "No recipes found"
    }

    private var emptyRecipesMessage: String {
        if recipeService.followSetIsEmpty {
            return "Nobody you follow has posted a recipe. Switch to Global to see everyone's."
        }
        return recipeService.loadFailed
            ? "Recipes come from other people's relays, so this one needs a connection."
            : "Nothing tagged zapcooking or nostrcooking came back."
    }

    /// Marketplace: NIP-15 products/auctions and NIP-99 classifieds from the
    /// listing relays. A listing opens as a sheet for the same reason a
    /// recipe does: it behaves the same in all three containers.
    @ViewBuilder
    var marketplaceGridView: some View {
        VStack(spacing: 12) {
            if !marketplaceService.categories.isEmpty {
                MarketplaceCategoryBar(categories: marketplaceService.categories, selected: $marketplaceService.selectedCategory)
            }

            if marketplaceService.isLoading && marketplaceService.visibleListings.isEmpty {
                ProgressView()
                    .controlSize(.large)
                    .tint(Color.havenPurple)
                    .padding(.vertical, 60)
            } else if marketplaceService.visibleListings.isEmpty {
                emptyMarketplaceStateView
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                    ForEach(marketplaceService.visibleListings) { listing in
                        MarketplaceCardView(listing: listing, profile: nostrService.profiles[listing.pubkey])
                            .onTapGesture { selectedListing = listing }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.vertical, 16)
        .onAppear { marketplaceService.loadIfNeeded() }
        // Sellers are mostly strangers, so their names aren't cached yet.
        .task(id: marketplaceService.listings.count) {
            nostrService.fetchMissingProfiles(for: Array(Set(marketplaceService.listings.map(\.pubkey))))
        }
    }

    private var emptyMarketplaceStateView: some View {
        VStack(spacing: 10) {
            Image(systemName: marketplaceService.loadFailed ? "wifi.slash" : "bag")
                .font(.appSystem(size: 34))
                .foregroundColor(.havenPurple.opacity(0.7))
            Text(marketplaceService.followSetIsEmpty || marketplaceService.scope == .following
                 ? "No listings from your follows"
                 : (marketplaceService.loadFailed ? "Could not reach any relay" : "No listings found"))
                .font(.appSystem(size: 16, weight: .bold))
            Text(marketplaceService.scope == .following
                 ? "Nobody you follow is selling anything. Switch to Global to see every listing."
                 : (marketplaceService.loadFailed
                    ? "Listings come from other people's relays, so this one needs a connection."
                    : "No products, auctions or classifieds with a photo came back."))
                .font(.appSystem(size: 13))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            if marketplaceService.scope == .following {
                Button("Show Global listings") { marketplaceService.setScope(.global) }
                    .buttonStyle(.borderless)
                    .foregroundColor(.havenPurple)
                    .padding(.top, 4)
            } else {
                Button("Try again") { marketplaceService.refresh() }
                    .buttonStyle(.borderless)
                    .foregroundColor(.havenPurple)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 60)
    }

    /// Reels: full-screen vertical video pager, one video per swipe.
    var reelsFeedView: some View {
        ReelsFeedView(
            feedService: feedService,
            onProfile: { showingProfileKey = IdentifiableString(id: $0) },
            onReply: { composeContext = ComposeContext(replyTo: feedService.replyTarget(for: $0), quoteTo: nil) },
            onOpenNote: { openNoteDetail($0) },
            onLike: { feedActionsValue.likeNote($0) },
            onShowGlobal: { reelsService.setScope(.global) },
            onPost: { modeComposer = .divine },
            isCovered: composeContext != nil || modeComposer != nil || showingProfileKey != nil || showingNoteId != nil
                || showingMediaUrl != nil || showingDashboard
        )
        // feedList is not on screen in diVines, so the collapsed tab bar's
        // compose button is answered here.
        .onReceive(NotificationCenter.default.publisher(for: .composeFromTabBar)) { note in
            guard (note.object as? Int) == 0 else { return }
            modeComposer = .divine
        }
    }

    /// Live streams: NIP-53 events that are running *and* carry a URL Apple's
    /// player can open. Never cached — a stream is only interesting while it is
    /// live, and a saved one is a gravestone.
    @ViewBuilder
    /// One conversation card for the threaded layout. `proxy` keeps the
    /// thread line still when a note opens in place; the Hashtags feed has no
    /// line tracking of its own and passes nil.
    func feedThreadCard(_ thread: FeedThread<FeedNote>, proxy: ScrollViewProxy?) -> some View {
        FeedThreadCard(
            thread: thread,
            // One open note across both condensed
            // layouts: the same gesture, so the same
            // selection.
            openNoteId: $expandedNoteId,
            isExpanded: Binding(
                get: { expandedThreadIds.contains(thread.rootId) },
                set: { isOpen in
                    if isOpen {
                        expandedThreadIds.insert(thread.rootId)
                    } else {
                        expandedThreadIds.remove(thread.rootId)
                    }
                }
            ),
            profileFor: { nostrService.profiles[$0] },
            rowDataFor: { note in
                rowDataCache[note.id] ?? FeedNoteRowData.resolve(
                    for: note,
                    feedService: feedService,
                    nostrService: nostrService
                )
            },
            onOpen: { openNoteDetail($0) },
            onReply: {
                composeContext = ComposeContext(
                    replyTo: feedService.replyTarget(for: $0),
                    quoteTo: nil
                )
            },
            onQuote: { composeContext = ComposeContext(replyTo: nil, quoteTo: feedService.quoteTarget(for: $0)) },
            onProfile: { openProfile($0) },
            onMedia: { url, urls in
                showingMediaUrl = IdentifiableURL(url: url, allURLs: urls)
            },
            rootUnavailable: feedService.unavailableNoteIds.contains(thread.rootId),
            lineTops: proxy == nil ? nil : threadLineTops,
            onOpenedInPlace: proxy.map { proxy in
                { id, y in holdThreadLine(id, at: y, proxy: proxy) }
            }
        )
    }

    /// Followed hashtags; rows open and act like the main timeline's, in
    /// whichever layout the feed's layout button picked.
    var hashtagsFeedView: some View {
        HashtagsFeedSection(threaded: isThreadedModeActive) { note in
            let isExpanded = expandedNoteId == note.id
            let row = feedNoteRowContent(
                note: note,
                profile: nostrService.profiles[note.pubkey],
                rowData: rowDataCache[note.id] ?? FeedNoteRowData.resolve(for: note, feedService: feedService, nostrService: nostrService),
                parentIsNext: false,
                isExpanded: isExpanded
            )
            .onAppear { nostrService.fetchMissingProfiles(for: [note.pubkey]) }
            #if os(iOS)
            // Same as the main timeline: a compact line opens in place on
            // tap, an expanded one navigates.
            if !isCompactModeActive || isExpanded {
                NoteNavigationLink(note: note) { row }
                    .buttonStyle(.plain)
            } else {
                row
            }
            #else
            row.onTapGesture {
                if !isCompactModeActive { showingNoteId = note.id }
            }
            #endif
        } threadRow: { thread in
            feedThreadCard(thread, proxy: nil)
                .padding(.horizontal, 12)
                .onAppear {
                    nostrService.fetchMissingProfiles(for: thread.entries.map(\.note.pubkey))
                    if thread.root == nil { feedService.fetchMissingNote(id: thread.rootId) }
                }
        }
        .environment(\.feedActions, feedActionsValue)
    }

    var liveGridView: some View {
        VStack(spacing: 12) {
            if liveService.isLoading && liveService.streams.isEmpty {
                ProgressView()
                    .controlSize(.large)
                    .tint(Color.havenPurple)
                    .padding(.vertical, 60)
            } else if liveService.streams.isEmpty {
                emptyLiveStateView
            } else {
                if liveService.scope == .global && liveService.globalGate == .newAccount {
                    liveUnfilteredBanner
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                    ForEach(liveService.streams) { stream in
                        LiveStreamCardView(stream: stream, profile: nostrService.profiles[stream.hostPubkey])
                            .contentShape(Rectangle())
                            .onTapGesture { playingStream = stream }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.vertical, 16)
        .onAppear { liveService.loadIfNeeded() }
    }

    private var emptyLiveText: LiveChat.EmptyLiveText {
        LiveChat.emptyLiveText(followSetIsEmpty: liveService.followSetIsEmpty,
                               loadFailed: liveService.loadFailed,
                               gate: liveService.scope == .global ? liveService.globalGate : nil)
    }

    private var emptyLiveStateView: some View {
        let text = emptyLiveText
        return VStack(spacing: 10) {
            Image(systemName: text.noConnection ? "wifi.slash" : "dot.radiowaves.left.and.right")
                .font(.appSystem(size: 34))
                .foregroundColor(.havenPurple.opacity(0.7))
            Text(text.title)
                .font(.appSystem(size: 16, weight: .bold))
            Text(text.message)
                .font(.appSystem(size: 13))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            switch text.action {
            case .showGlobal:
                Button("Show Global streams") { liveService.setScope(.global) }
                    .buttonStyle(.borderless)
                    .foregroundColor(.havenPurple)
                    .padding(.top, 4)
            case .tryAgain:
                Button("Try again") { liveService.refresh() }
                    .buttonStyle(.borderless)
                    .foregroundColor(.havenPurple)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 60)
    }

    /// Global with no web of trust yet shows everyone (minus adult streams);
    /// say so, as the topic feed does.
    private var liveUnfilteredBanner: some View {
        Label("Unfiltered: people you don't know yet", systemImage: "eye")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .accessibilityLabel("Unfiltered. These streams are from people you don't know yet.")
    }
}
