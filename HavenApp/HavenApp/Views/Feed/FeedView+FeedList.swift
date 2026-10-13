import SwiftUI

/// Observes the feed/profile state that drives the per-row data cache and routes
/// each change to a targeted incremental updater. Extracted into its own
/// `ViewModifier` so the (large) `FeedView` body stays within the Swift
/// type-checker's budget — the `onChange` type inference happens in this tiny
/// body instead of inline in the main chain.
private struct RowDataCacheObservers: ViewModifier {
    @ObservedObject var feedService: FeedService
    @ObservedObject var nostrService: NostrService
    let onFiltered: () -> Void
    let onLikes: (Set<String>, Set<String>) -> Void
    let onMyReactions: ([String: EngagementTracker.MyReaction], [String: EngagementTracker.MyReaction]) -> Void
    let onReposts: (Set<String>, Set<String>) -> Void
    let onZaps: ([String: Int], [String: Int]) -> Void
    let onProfiles: (Set<String>) -> Void
    let onFollowsChanged: () -> Void
    let onNoteStats: ([String: NoteStats], [String: NoteStats]) -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: feedService.filteredNotes) { _, _ in onFiltered() }
            .onChange(of: feedService.likedEventIds) { old, new in onLikes(old, new) }
            .onChange(of: feedService.myReactions) { old, new in onMyReactions(old, new) }
            .onChange(of: feedService.repostedEventIds) { old, new in onReposts(old, new) }
            .onChange(of: feedService.zappedEventIds) { old, new in onZaps(old, new) }
            .onChange(of: nostrService.profileUpdates) { _, signal in onProfiles(signal.pubkeys) }
            // Follow-list changes (follow/unfollow, or an account switch swapping
            // in a different follow list) flip isFollowed/isParentFollowed on
            // potentially every row, so fall back to a full rebuild. Rare event.
            .onChange(of: feedService.followedPubkeys) { _, _ in onFollowsChanged() }
            .onChange(of: feedService.noteStats) { old, new in onNoteStats(old, new) }
            // Blocking can hide a thread's root or an ancestor without
            // changing the visible note list, so regroup on it directly.
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("BlockedAccountsUpdated"))) { _ in onFiltered() }
    }
}

/// A thread parent / repost original / quoted note just arrived. It changes no
/// row's own id and no other published property, so this is the only thing that
/// can clear a row's loading skeleton once its rowData is cached.
///
/// Its own modifier rather than an eighth `onChange` in `RowDataCacheObservers`:
/// one more link in that chain puts it over the type-checker's budget and the
/// file stops compiling ("unable to type-check this expression in reasonable
/// time"). Any further observer should be a separate modifier too.
private struct ReferencedNoteObserver: ViewModifier {
    @ObservedObject var feedService: FeedService
    let onReferencedNotes: (Set<String>) -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: feedService.referencedNoteUpdates) { _, signal in onReferencedNotes(signal.ids) }
    }
}

extension FeedView {
    /// Warms the rows just below `noteId` — photos, avatars, parent and quoted
    /// notes — so they are ready when they scroll on screen instead of starting
    /// to load there.
    private func prefetchAhead(ofNote noteId: String) {
        let notes = feedService.filteredNotes
        guard let index = notes.firstIndex(where: { $0.id == noteId }) else { return }
        FeedPrefetcher.warm(notes[(index + 1)..<min(index + 1 + FeedPrefetcher.lookahead, notes.count)],
                            feedService: feedService, nostrService: nostrService)
    }

    private func prefetchAhead(ofThread rootId: String) {
        guard let index = feedThreads.firstIndex(where: { $0.rootId == rootId }) else { return }
        let upcoming = feedThreads[(index + 1)..<min(index + 1 + FeedPrefetcher.lookahead, feedThreads.count)]
        // A collapsed card shows its root and first reply; warm those.
        FeedPrefetcher.warm(upcoming.flatMap { $0.entries.prefix(2).map(\.note) },
                            feedService: feedService, nostrService: nostrService)
    }

    /// Keeps a thread line where it was tapped. Opening it closed whatever
    /// was open; if that sat above, the line would slide up, possibly out of
    /// view. A line whose top was already above the screen is brought down
    /// to the top edge.
    ///
    /// The scroll runs with no animation from the line's own geometry change,
    /// so it lands in the same frame as the close. An animated scroll a
    /// runloop later showed as the line jumping and then sliding back.
    func holdThreadLine(_ noteId: String, at y: CGFloat, proxy: ScrollViewProxy) {
        let height = threadLineTops.viewportHeight
        guard height > 0 else { return }
        let fraction = min(max(y / height, 0), 1)
        let anchor = UnitPoint(x: 0.5, y: fraction)
        threadLineTops.hold = (noteId, y, {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) {
                proxy.scrollTo(ThreadLineTops.anchorId(for: noteId), anchor: anchor)
            }
        })
        // The open line sat below the tapped one, so nothing above moved.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [threadLineTops] in
            if threadLineTops.hold?.noteId == noteId { threadLineTops.hold = nil }
        }
    }

    var feedList: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .top) {
                ScrollView {
                    VStack(spacing: 0) {
                        // Anchor for scroll-to-top
                        Color.clear
                            .frame(height: 1)
                            .id("top")

                        if feedService.feedMode == .media {
                            mediaGridView
                        } else if feedService.feedMode == .articles {
                            articleListView
                        } else if feedService.feedMode == .recipes {
                            recipeGridView
                        } else if feedService.feedMode == .marketplace {
                            marketplaceGridView
                        } else if feedService.feedMode == .hashtags {
                            hashtagsFeedView
                        } else if feedService.feedMode == .music {
                            MusicBrowserView()
                        } else if feedService.feedMode == .live {
                            liveGridView
                        } else {
                            LazyVStack(spacing: 12) {

                        // Loading header
                        if feedService.isLoadingFeed && feedService.notes.isEmpty {
                            ForEach(0..<5, id: \.self) { _ in
                                FeedNoteSkeletonRow()
                                    .padding(.horizontal, 16)
                            }
                        }

                        if feedService.feedMode == .polls && feedService.filteredNotes.isEmpty && !feedService.isLoadingFeed {
                            PollsEmptyStateView(scope: feedService.pollsFeedMode, status: feedService.pollStatusFilter,
                                                onPost: configService.activeAccountHexPubkey.isEmpty ? nil : { modeComposer = .poll })
                        }

                        if isThreadedModeActive {
                            ForEach(feedThreads) { thread in
                                feedThreadCard(thread, proxy: proxy)
                                .padding(.horizontal, 12)
                                .onAppear { prefetchAhead(ofThread: thread.rootId) }
                                .trackFeedVisibility(thread.rootId, in: visibleRows)
                            }
                        } else {
                        ForEach(feedService.filteredNotes) { note in
                            let profile = nostrService.profiles[note.pubkey]
                            let rowData = rowDataCache[note.id] ?? FeedNoteRowData.resolve(
                                for: note,
                                feedService: feedService,
                                nostrService: nostrService
                            )

                            // Optimization: If the parent is the very next note in the feed,
                            // don't show the redundant parent header.
                            let parentIsNext = feedService.parentIsNextNote.contains(note.id)

                            #if os(iOS)
                            let isExpanded = (expandedNoteId == note.id)
                            let shouldUseNavLink = !isCompactModeActive || isExpanded

                            Group {
                                if shouldUseNavLink {
                                    NoteNavigationLink(note: note) {
                                        feedNoteRowContent(note: note, profile: profile, rowData: rowData, parentIsNext: parentIsNext, isExpanded: isExpanded)
                                    }
                                    .buttonStyle(.plain)
                                } else {
                                    feedNoteRowContent(note: note, profile: profile, rowData: rowData, parentIsNext: parentIsNext, isExpanded: isExpanded)
                                }
                            }
                            .onAppear { prefetchAhead(ofNote: note.id) }
                            .trackFeedVisibility(note.id, in: visibleRows)
                            #else
                            let isExpanded = (expandedNoteId == note.id)
                            feedNoteRowContent(note: note, profile: profile, rowData: rowData, parentIsNext: parentIsNext, isExpanded: isExpanded)
                                .onTapGesture {
                                    // On macOS in full mode, open note detail
                                    if !isCompactModeActive {
                                        showingNoteId = note.id
                                    }
                                }
                                .onAppear { prefetchAhead(ofNote: note.id) }
                            #endif
                        }
                        }

                        // Infinite scroll sentinel — triggers loadMore when visible
                        if !feedService.filteredNotes.isEmpty {
                            Color.clear
                                .frame(height: 1)
                                .onAppear { feedService.loadMore() }

                            if feedService.isLoadingFeed {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small).tint(Color.havenPurple)
                                    Text(String(localized: "feed.loading.indicator"))
                                        .font(.appSystem(size: 12, weight: .semibold, design: .monospaced))
                                }
                                .foregroundColor(.secondary)
                                .padding(.vertical, 12)
                                .frame(maxWidth: .infinity)
                            }
                        }

                    }
                    .environment(\.feedActions, feedActionsValue)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    }
                    }
                    .tabBarBottomPadding()
                    // The last post scrolls clear of the open meter.
                    .padding(.bottom, fillGuide.meterLift)
                }
                // A switched account gets its own scroll view, cross-faded in at
                // the top. Kept, this one diffed a whole feed of rows into the
                // old scroll offset, held on to the old anchored note when both
                // accounts had it, and then animated a scroll to the top on top
                // of the fade — rows shuffled and slid instead of the feed
                // simply changing.
                .coordinateSpace(.named(ThreadLineTops.coordinateSpace))
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                    threadLineTops.viewportHeight = $0
                }
                .id(configService.activeAccountHexPubkey)
                .transition(.opacity)
                .refreshable {
                    isRefreshing = true
                    // Pulling down takes in the posts waiting behind the New
                    // Posts pill, the only way to reach them with it switched off.
                    if !feedService.pendingNotes.isEmpty { feedService.applyPendingNotes() }
                    feedService.refresh()
                    // Hold the indicator until loading finishes
                    while feedService.isLoadingFeed {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                    isRefreshing = false
                }
                .tint(Color.secondary.opacity(0.6))
                .opacity(layoutFadedOut ? 0 : 1)
                .scrollPosition(id: $scrolledNoteID)
                .onChange(of: pendingLayoutAnchor) { _, anchor in
                    guard let anchor else { return }
                    // Next runloop turn, once the new layout's rows exist.
                    let animation = pendingLayoutAnimation
                    DispatchQueue.main.async {
                        withAnimation(animation) { proxy.scrollTo(anchor, anchor: .top) }
                        pendingLayoutAnchor = nil
                        pendingLayoutAnimation = nil
                    }
                }
                .scrollDirectionTracking(feedService: feedService, isAtTop: $isAtTop)
                .softTopScrollEdge()
                .onChange(of: feedService.isLoadingFeed) { _, isLoading in
                    if !isLoading && feedService.shouldScrollToTopOnLoad {
                        feedService.shouldScrollToTopOnLoad = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            withAnimation(Motion.scrollJump) {
                                proxy.scrollTo("top", anchor: .top)
                            }
                        }
                    }
                }
                .onChange(of: feedService.visiblePendingCount) { _, count in
                    // Auto-apply pending notes when autoLoad is on, but only
                    // if the user is at the top of the feed to avoid disrupting
                    // their scroll position. Debounced to prevent duplicate calls.
                    if count > 0 && configService.config.autoLoadNewPosts && !feedService.isLoadingFeed && isAtTop {
                        scheduleAutoLoad(delay: 1.5)
                    }
                }
                .onChange(of: isAtTop) { _, atTop in
                    // When the user scrolls back to the top, auto-apply any
                    // accumulated pending notes if auto-load is enabled.
                    if atTop && configService.config.autoLoadNewPosts && feedService.visiblePendingCount > 0 && !feedService.isLoadingFeed {
                        scheduleAutoLoad(delay: 0.5)
                    }
                }
                .modifier(RowDataCacheObservers(
                    feedService: feedService,
                    nostrService: nostrService,
                    onFiltered: { reconcileRowDataCache(); rebuildThreadsIfNeeded() },
                    onLikes: { updateRowDataForLikes(old: $0, new: $1) },
                    onMyReactions: { updateRowDataForMyReactions(old: $0, new: $1) },
                    onReposts: { updateRowDataForReposts(old: $0, new: $1) },
                    onZaps: { updateRowDataForZaps(old: $0, new: $1) },
                    onProfiles: { refreshRowsForPubkeys($0) },
                    onFollowsChanged: { rebuildRowDataCache() },
                    onNoteStats: { updateRowDataForNoteStats(old: $0, new: $1) }
                ))
                .modifier(ReferencedNoteObserver(
                    feedService: feedService,
                    onReferencedNotes: {
                        refreshRowsForReferencedNotes($0)
                        regroupIfGapFilled($0)
                    }
                ))
                // Layout is stored per feed, so switching feeds can switch
                // layout. Regroup immediately rather than waiting on the next
                // filteredNotes change, which a cached feed may not produce.
                .onChange(of: feedService.feedMode) { _, _ in
                    rebuildThreadsIfNeeded(immediate: true)
                }
                .onChange(of: feedService.feedThreadReplies.count) { _, _ in
                    rebuildThreadsIfNeeded()
                }

                // Floating "New Posts" indicator — shown when auto-load is off,
                // or when auto-load is on but the user has scrolled down.
                // It folds away with the bars; folded, `foldedNewPostsPill`
                // stands in for it in the top bar's row.
                if showsNewPostsButton {
                    Group {
                        #if os(iOS)
                        NewPostsFold(isEnabled: isCompactWidth) {
                            newPostsButton(compact: false) { scrollToTopAfterLoad(proxy) }
                        }
                        #else
                        newPostsButton(compact: false) { scrollToTopAfterLoad(proxy) }
                        #endif
                    }
                    .padding(.top, 12)
                    .ambientPill()
                    // Drops out from under the top bar rather than sliding in
                    // from off-screen above it.
                    .transition(.asymmetric(
                        insertion: .offset(y: -16)
                            .combined(with: .scale(scale: 0.85, anchor: .top))
                            .combined(with: .opacity),
                        removal: .opacity.combined(with: .scale(scale: 0.8))
                    ))
                    .zIndex(1)
                }

            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("FeedTabReselected"))) { _ in
                if !navigationPath.isEmpty {
                    // Inside a note detail — pop back to feed list (keeps scroll position)
                    navigationPath = NavigationPath()
                } else if !isAtTop {
                    // At feed root but scrolled down — scroll to top
                    withAnimation(Motion.scrollJump) {
                        proxy.scrollTo("top", anchor: .top)
                    }
                } else {
                    // Already at feed root and at top — refresh
                    FeedService.shared.refresh()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ScrollToTop"))) { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    withAnimation(Motion.scrollJump) {
                        proxy.scrollTo("top", anchor: .top)
                    }
                }
            }
            .onChange(of: configService.activeAccountHexPubkey) { _, _ in
                // Identity change flips isOwnNote on every row; rebuild fully so
                // overlapping notes (global/popular feeds) reflect the new account.
                // No scroll to the top: the scroll view is keyed by account, so
                // the new one already starts there, so the at-top state (which
                // gates auto-loading new posts) and the tab bar follow it.
                scrolledNoteID = nil
                isAtTop = true
                ChromeCollapse.shared.reset()
                rebuildRowDataCache()
                rebuildThreadsIfNeeded()
            }
            .onReceive(NotificationCenter.default.publisher(for: .composeFromTabBar)) { note in
                guard (note.object as? Int) == 0 else { return }
                openComposer()
            }
            // ⌘R on an iPad keyboard: the same as pulling down.
            .modifier(RefreshesOnTabCommand(tab: 0, isActive: { !feedService.isLoadingFeed }) {
                if !feedService.pendingNotes.isEmpty { feedService.applyPendingNotes() }
                feedService.refresh()
            })
        }
        .overlay(alignment: .bottomTrailing) {
            #if os(iOS)
            ChromeFold(anchor: .bottomTrailing) {
                Button {
                    openComposer()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: ModeComposer(feedMode: feedService.feedMode)?.symbolName ?? "square.and.pencil")
                            .font(.appSystem(size: 15, weight: .bold))
                        Text(ModeComposer(feedMode: feedService.feedMode)?.buttonTitle ?? String(localized: "feed.action.post"))
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
                .accessibilityLabel(ModeComposer(feedMode: feedService.feedMode)?.accessibilityLabel ?? "Compose new post")
                .buttonStyle(PressScaleButtonStyle())
                // Shares the row above the tab bar with the music mini player.
                .modifier(FloatingButtonSlot())
                // Post keeps priority over the Fill your feed meter.
                .padding(.bottom, fillGuide.meterLift)
                .animation(Motion.chrome, value: fillGuide.meterLift)
                .hoverEffect(.lift)
            }
            #endif
        }
    }

    /// The post button writes what the feed shows: a diVine in diVines, an
    /// article in Articles, a recipe in Recipes, a listing in Marketplace,
    /// a note everywhere else.
    private func openComposer() {
        if let composer = ModeComposer(feedMode: feedService.feedMode) {
            modeComposer = composer
        } else {
            composeContext = ComposeContext(replyTo: nil, quoteTo: nil)
        }
    }
}
