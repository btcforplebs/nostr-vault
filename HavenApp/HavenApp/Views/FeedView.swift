import SwiftUI
import ImageIO
#if canImport(UIKit)
import UIKit
#endif

struct IdentifiableString: Identifiable {
    let id: String
}



@available(iOS 18.0, *)
@available(macOS 15.0, iOS 18.0, *)
private struct ScrollDirectionModifier: ViewModifier {
    @ObservedObject var feedService: FeedService
    var isAtTopBinding: Binding<Bool>?
    @State private var isScrollingDown = false

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.contentOffset.y
            } action: { oldValue, newValue in
                let delta = newValue - oldValue
                if abs(delta) > 8 {
                    let scrollingDown = delta > 0
                    if scrollingDown != isScrollingDown {
                        isScrollingDown = scrollingDown
                        // Respect the user's "disable tab bar animation" setting:
                        // never publish a "scrolling down" flip so the tab bar and
                        // per-screen FABs stay fully expanded. Force-expand writes
                        // (below) always run so a stale collapsed state can recover.
                        if !(scrollingDown && ConfigService.shared.config.disableTabBarAnimation) {
                            feedService.feedScrollingDown = scrollingDown
                        }
                    }
                }
                // Only force-expand when truly scrolled back to the very top.
                // Guard both writes: `onScrollGeometryChange` fires every frame
                // while the offset changes, and near the top (including the iOS
                // rubber-band bounce) `newValue` oscillates around 0 every frame.
                // Writing `feedScrollingDown` unconditionally would publish
                // `objectWillChange` on the shared FeedService each frame —
                // re-rendering the tab bar and every feed row dozens of times a
                // second, the framerate glitch seen at the top of every feed.
                if newValue <= 0 {
                    if feedService.feedScrollingDown {
                        feedService.feedScrollingDown = false
                    }
                    if isScrollingDown {
                        isScrollingDown = false
                    }
                }

                // Track whether the user is at the top of the feed
                if let binding = isAtTopBinding {
                    let atTop = newValue <= 10
                    if atTop != binding.wrappedValue {
                        binding.wrappedValue = atTop
                    }
                }
            }
    }
}

extension View {
    @ViewBuilder
    func scrollDirectionTracking(feedService: FeedService, isAtTop: Binding<Bool>? = nil) -> some View {
        if #available(macOS 15.0, iOS 18.0, *) {
            self.modifier(ScrollDirectionModifier(feedService: feedService, isAtTopBinding: isAtTop))
        } else {
            self
        }
    }
}

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
    let onReposts: (Set<String>, Set<String>) -> Void
    let onZaps: ([String: Int], [String: Int]) -> Void
    let onProfiles: (Set<String>) -> Void
    let onFollowsChanged: () -> Void
    let onNoteStats: ([String: NoteStats], [String: NoteStats]) -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: feedService.filteredNotes) { _, _ in onFiltered() }
            .onChange(of: feedService.likedEventIds) { old, new in onLikes(old, new) }
            .onChange(of: feedService.repostedEventIds) { old, new in onReposts(old, new) }
            .onChange(of: feedService.zappedEventIds) { old, new in onZaps(old, new) }
            .onChange(of: nostrService.profileUpdates) { _, signal in onProfiles(signal.pubkeys) }
            // Follow-list changes (follow/unfollow, or an account switch swapping
            // in a different follow list) flip isFollowed/isParentFollowed on
            // potentially every row, so fall back to a full rebuild. Rare event.
            .onChange(of: feedService.followedPubkeys) { _, _ in onFollowsChanged() }
            .onChange(of: feedService.noteStats) { old, new in onNoteStats(old, new) }
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

// MARK: - FeedView

struct FeedView: View {
    @StateObject private var feedService = FeedService.shared
    @EnvironmentObject var relayManager: RelayProcessManager
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var nostrService: NostrService
    @ObservedObject private var pendingManager = PendingPostManager.shared
    @State private var composeContext: ComposeContext?
    @State private var showingRelayStatus = false
    @State private var showingNoteId: String?
    @State private var showingProfileKey: IdentifiableString?
    @State private var showingMediaUrl: IdentifiableURL?
    /// macOS presents the article reader as a sheet; iOS pushes it.
    @State private var showingArticle: ArticleRoute?
    @StateObject private var recipeService = RecipeFeedService.shared
    @StateObject private var liveService = LiveFeedService.shared
    @State private var showingGlobalLiveWarning = false
    @State private var playingStream: LiveStream?
    @State private var selectedGridMediaNoteId: String?
    @State private var isShowingGridMediaViewer = false
    @State private var gridMediaSnapshot: [FeedNote] = []
    @State private var galleryDragOffset: CGSize = .zero
    @State private var isRefreshing = false
    @State private var showingGlobalMediaWarning = false
    /// Same warning, raised before Recipes switches to the global set.
    @State private var showingGlobalRecipeWarning = false
    @State private var isAtTop: Bool = true
    @State private var scrolledNoteID: String?
    @State private var lastScrollOffset: CGFloat = 0
    @State private var isScrollingDown: Bool = false
    @State private var navigationPath = NavigationPath()
    /// Non-nil when an iPad split pane owns the note detail column.
    @Environment(\.noteDetailSelection) private var noteDetailSelection
    /// Debounce work item for auto-loading pending notes so overlapping
    /// onChange triggers don't queue duplicate applyPendingNotes() calls.
    @State private var autoLoadWork: DispatchWorkItem?
    /// Debounce work item for rebuilding the row data cache to prevent
    /// expensive synchronous operations during active scrolling.
    @State private var cacheRebuildWork: DispatchWorkItem?
    /// Cache of pre-resolved row data keyed by note ID. Invalidated when
    /// filteredNotes changes so we avoid re-running resolve() on every
    /// SwiftUI re-render triggered by unrelated state changes.
    @State private var rowDataCache: [String: FeedNoteRowData] = [:]

    /// Compact mode state: tracks which note is currently expanded (nil = all collapsed)
    @State private var expandedNoteId: String? = nil

    // MARK: - Helper Properties

    /// Whether compact ("condensed") mode is enabled for the current feed, honoring
    /// the per-feed user override and falling back to per-feed defaults: Following
    /// defaults OFF, all other timeline feeds default ON.
    private var compactModeEnabledForCurrentFeed: Bool {
        if let stored = configService.config.feedCompactModes[feedService.feedMode.rawValue] {
            return stored
        }
        switch feedService.feedMode {
        case .following, .articles, .recipes, .live:
            return false
        case .discovery, .global, .popular, .media:
            return configService.config.useFeedCompactMode
        }
    }

    /// Toggle and persist compact mode for the current feed.
    private func toggleCompactModeForCurrentFeed() {
        configService.config.feedCompactModes[feedService.feedMode.rawValue] = !compactModeEnabledForCurrentFeed
        configService.save()
        expandedNoteId = nil
    }

    /// Compact mode is active for all feeds except Media grid
    private var isCompactModeActive: Bool {
        guard compactModeEnabledForCurrentFeed else { return false }
        switch feedService.feedMode {
        case .following, .discovery, .global, .popular:
            return true
        // Articles and Media are card/grid layouts, not timeline rows —
        // compact mode has nothing to condense.
        case .media, .articles, .recipes, .live:
            return false
        }
    }

    // MARK: - Feed Trailing Toolbar (inline vs. compact menu)

    @ViewBuilder
    private var feedTrailingToolbarInline: some View {
        HStack(spacing: 4) {
            IconFilterButton(icon: compactModeEnabledForCurrentFeed ? "rectangle.compress.vertical" : "rectangle.expand.vertical", tooltip: "Compact View", isSelected: compactModeEnabledForCurrentFeed, color: .havenPurple) {
                toggleCompactModeForCurrentFeed()
            }

            Divider()
                .frame(height: 20)
                .padding(.horizontal, 4)

            if feedService.feedMode == .media {
                IconFilterButton(icon: feedService.mediaFeedMode == .following ? "person.2.fill" : "person.2", tooltip: "Following", isSelected: feedService.mediaFeedMode == .following, color: .havenPurple) {
                    feedService.mediaFeedMode = .following
                    feedService.refresh()
                }
                IconFilterButton(icon: "globe", tooltip: "Global", isSelected: feedService.mediaFeedMode == .global, color: .havenPurple) {
                    showingGlobalMediaWarning = true
                }
            } else if feedService.feedMode == .recipes {
                IconFilterButton(icon: recipeService.scope == .following ? "person.2.fill" : "person.2", tooltip: "Following", isSelected: recipeService.scope == .following, color: .havenPurple) {
                    recipeService.setScope(.following)
                }
                IconFilterButton(icon: "globe", tooltip: "Global", isSelected: recipeService.scope == .global, color: .havenPurple) {
                    showingGlobalRecipeWarning = true
                }
            } else if feedService.feedMode == .live {
                IconFilterButton(icon: liveService.scope == .following ? "person.2.fill" : "person.2", tooltip: "Following", isSelected: liveService.scope == .following, color: .havenPurple) {
                    liveService.setScope(.following)
                }
                IconFilterButton(icon: "globe", tooltip: "Global", isSelected: liveService.scope == .global, color: .havenPurple) {
                    showingGlobalLiveWarning = true
                }
            } else if feedService.feedMode == .popular {
                IconFilterButton(icon: feedService.popularFilter == .follows ? "person.2.fill" : "person.2", tooltip: "Follows", isSelected: feedService.popularFilter == .follows, color: .havenPurple) {
                    feedService.popularFilter = feedService.popularFilter == .follows ? .all : .follows
                    feedService.recomputeFilteredNotes()
                }
                IconFilterButton(icon: feedService.popularFilter == .nonFollows ? "globe.americas.fill" : "globe.americas", tooltip: "Non-Follows", isSelected: feedService.popularFilter == .nonFollows, color: .havenPurple) {
                    feedService.popularFilter = feedService.popularFilter == .nonFollows ? .all : .nonFollows
                    feedService.recomputeFilteredNotes()
                }
                IconFilterButton(icon: feedService.showPopularEngagement ? "chart.bar.fill" : "chart.bar", tooltip: "Engagement", isSelected: feedService.showPopularEngagement, color: .havenPurple) {
                    feedService.showPopularEngagement.toggle()
                }
            } else {
                IconFilterButton(icon: configService.config.autoLoadNewPosts ? "bolt.circle.fill" : "bolt.circle", tooltip: "Auto-load", isSelected: configService.config.autoLoadNewPosts, color: .havenPurple) {
                    configService.config.autoLoadNewPosts.toggle()
                    configService.save()
                }
                IconFilterButton(icon: "arrow.2.squarepath", tooltip: "Reposts", isSelected: configService.config.showReposts, color: .havenPurple) {
                    configService.config.showReposts.toggle()
                    configService.save()
                    feedService.recomputeFilteredNotes()
                }
                IconFilterButton(icon: configService.config.showReplies ? "message.fill" : "message", tooltip: "Replies", isSelected: configService.config.showReplies, color: .havenPurple) {
                    configService.config.showReplies.toggle()
                    configService.save()
                    feedService.recomputeFilteredNotes()
                }
            }
        }
    }

    @ViewBuilder
    private var feedTrailingToolbarMenu: some View {
        Menu {
            Button {
                toggleCompactModeForCurrentFeed()
            } label: {
                Label(
                    compactModeEnabledForCurrentFeed ? "Expanded View" : "Compact View",
                    systemImage: compactModeEnabledForCurrentFeed ? "rectangle.expand.vertical" : "rectangle.compress.vertical"
                )
            }

            Divider()

            if feedService.feedMode == .media {
                Button {
                    feedService.mediaFeedMode = .following
                    feedService.refresh()
                } label: {
                    Label("Following", systemImage: "person.2.fill")
                }
                Button { showingGlobalMediaWarning = true } label: {
                    Label("Global", systemImage: "globe")
                }
            } else if feedService.feedMode == .recipes {
                Button { recipeService.setScope(.following) } label: {
                    Label("Following", systemImage: "person.2.fill")
                }
                Button { showingGlobalRecipeWarning = true } label: {
                    Label("Global", systemImage: "globe")
                }
            } else if feedService.feedMode == .live {
                Button { liveService.setScope(.following) } label: {
                    Label("Following", systemImage: "person.2.fill")
                }
                Button { showingGlobalLiveWarning = true } label: {
                    Label("Global", systemImage: "globe")
                }
            } else if feedService.feedMode == .popular {
                Button {
                    feedService.popularFilter = feedService.popularFilter == .follows ? .all : .follows
                    feedService.recomputeFilteredNotes()
                } label: {
                    Label("Follows", systemImage: "person.2.fill")
                }
                Button {
                    feedService.popularFilter = feedService.popularFilter == .nonFollows ? .all : .nonFollows
                    feedService.recomputeFilteredNotes()
                } label: {
                    Label("Non-Follows", systemImage: "globe.americas")
                }
                Button {
                    feedService.showPopularEngagement.toggle()
                } label: {
                    Label("Engagement", systemImage: "chart.bar")
                }
            } else {
                Button {
                    configService.config.autoLoadNewPosts.toggle()
                    configService.save()
                } label: {
                    Label("Auto-load", systemImage: configService.config.autoLoadNewPosts ? "bolt.circle.fill" : "bolt.circle")
                }
                Button {
                    configService.config.showReposts.toggle()
                    configService.save()
                    feedService.recomputeFilteredNotes()
                } label: {
                    Label("Reposts", systemImage: "arrow.2.squarepath")
                }
                Button {
                    configService.config.showReplies.toggle()
                    configService.save()
                    feedService.recomputeFilteredNotes()
                } label: {
                    Label("Replies", systemImage: configService.config.showReplies ? "message.fill" : "message")
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

    // MARK: - Helper Functions

    @ViewBuilder
    private func feedNoteRowContent(note: FeedNote, profile: FeedProfile?, rowData: FeedNoteRowData, parentIsNext: Bool, isExpanded: Bool) -> some View {
        FeedNoteRow(
            note: note,
            profile: profile,
            rowData: rowData,
            onReply: {
                if note.kind == 6, let refId = note.repostedEventId,
                   let original = feedService.findNote(id: refId) {
                    composeContext = ComposeContext(replyTo: original, quoteTo: nil)
                } else {
                    composeContext = ComposeContext(replyTo: note, quoteTo: nil)
                }
            },
            onQuote: {
                composeContext = ComposeContext(replyTo: nil, quoteTo: note)
            },
            onProfile: { pubkey in
                showingProfileKey = IdentifiableString(id: pubkey)
            },
            onMedia: { url, urls in
                showingMediaUrl = IdentifiableURL(url: url, allURLs: urls)
            },
            showParent: !parentIsNext,
            isReplyToNext: parentIsNext,
            useCompactMode: isCompactModeActive,
            isExpanded: isExpanded,
            onTapRow: {
                // Toggle expansion: if already expanded, collapse it; otherwise expand it
                expandedNoteId = (expandedNoteId == note.id) ? nil : note.id
            }
        )
        .overlay(alignment: .topTrailing) {
            if feedService.feedMode == .popular && feedService.showPopularEngagement,
               let score = feedService.popularNoteScores[note.id] {
                engagementBadge(score: score)
                    .padding(.top, 8)
                    .padding(.trailing, 8)
            }
        }
        .padding(.horizontal, isCompactModeActive && !isExpanded ? 8 : 16)
    }

    var body: some View {
        #if os(iOS)
        if noteDetailSelection != nil {
            // iPad two-pane layout: the enclosing NoteSplitPane owns the detail
            // column, so the feed must NOT wrap itself in a stack — a private
            // stack here would swallow selections and push over the list again.
            rootContent
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.hidden, for: .navigationBar)
                // The article reader is pushed onto the enclosing NoteSplitPane
                // stack in two-pane mode, so the destination has to be
                // registered on both branches.
                .navigationDestination(for: ArticleRoute.self) { route in
                    ArticleReaderView(note: route.note)
                }
        } else {
            NavigationStack(path: $navigationPath) {
                rootContent
                    .navigationTitle("")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarBackground(.hidden, for: .navigationBar)
                    .navigationDestination(for: FeedNote.self) { note in
                        NoteDetailView(note: note)
                    }
                    .navigationDestination(for: ArticleRoute.self) { route in
                        ArticleReaderView(note: route.note)
                    }
            }
        }
        #else
        VStack(spacing: 0) {
            macFeedHeader
            Divider()
            rootContent
        }
        #endif
    }

    #if os(macOS)
    private var macFeedHeader: some View {
        HStack(spacing: 12) {
            // Connection dot
            Button(action: { showingRelayStatus = true }) {
                Circle()
                    .fill(feedService.connectionDotColor)
                    .frame(width: 10, height: 10)
                    .shadow(color: feedService.connectionDotColor.opacity(0.8), radius: 3)
            }
            .buttonStyle(.plain)
            .help(String(localized: "feed.help.relayStatus"))
            .accessibilityLabel("Relay status")
            .accessibilityValue(feedService.connectionStatus)

            // Feed mode picker
            Menu {
                ForEach(FeedMode.allCases, id: \.self) { mode in
                    Button(action: { feedService.switchMode(mode) }) {
                        let displayName = mode == .discovery ? "Discover" : mode.rawValue
                        if feedService.feedMode == mode {
                            Label(displayName, systemImage: "checkmark")
                        } else {
                            Text(displayName)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    let displayName = feedService.feedMode == .discovery ? "Discover" : feedService.feedMode.rawValue
                    Text(displayName)
                        .font(.appSystem(size: 13, weight: .semibold))
                    Image(systemName: "chevron.down")
                        .font(.appSystem(size: 9, weight: .bold))
                }
                .foregroundColor(.primary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()

            if feedService.feedMode == .media {
                Button(action: {
                    feedService.mediaFeedMode = .following
                    feedService.refresh()
                }) {
                    Image(systemName: feedService.mediaFeedMode == .following ? "person.2.fill" : "person.2")
                        .font(.appSystem(size: 15, weight: .semibold))
                        .foregroundColor(feedService.mediaFeedMode == .following ? Color.havenPurple : .secondary)
                }
                .buttonStyle(.plain)
                .help(String(localized: "feed.help.followingMedia"))

                Button(action: {
                    showingGlobalMediaWarning = true
                }) {
                    Image(systemName: "globe")
                        .font(.appSystem(size: 15, weight: .semibold))
                        .foregroundColor(feedService.mediaFeedMode == .global ? Color.havenPurple : .secondary)
                }
                .buttonStyle(.plain)
                .help(String(localized: "feed.help.globalMedia"))
            } else if feedService.feedMode == .recipes {
                Button(action: { recipeService.setScope(.following) }) {
                    Image(systemName: recipeService.scope == .following ? "person.2.fill" : "person.2")
                        .font(.appSystem(size: 15, weight: .semibold))
                        .foregroundColor(recipeService.scope == .following ? Color.havenPurple : .secondary)
                }
                .buttonStyle(.plain)
                .help("Recipes from people you follow")

                Button(action: { showingGlobalRecipeWarning = true }) {
                    Image(systemName: "globe")
                        .font(.appSystem(size: 15, weight: .semibold))
                        .foregroundColor(recipeService.scope == .global ? Color.havenPurple : .secondary)
                }
                .buttonStyle(.plain)
                .help("Recipes from everyone")
            } else if feedService.feedMode == .live {
                Button(action: { liveService.setScope(.following) }) {
                    Image(systemName: liveService.scope == .following ? "person.2.fill" : "person.2")
                        .font(.appSystem(size: 15, weight: .semibold))
                        .foregroundColor(liveService.scope == .following ? Color.havenPurple : .secondary)
                }
                .buttonStyle(.plain)
                .help("Streams from people you follow")

                Button(action: { showingGlobalLiveWarning = true }) {
                    Image(systemName: "globe")
                        .font(.appSystem(size: 15, weight: .semibold))
                        .foregroundColor(liveService.scope == .global ? Color.havenPurple : .secondary)
                }
                .buttonStyle(.plain)
                .help("Streams from everyone")
            } else if feedService.feedMode == .popular {
                // My Follows filter
                Button(action: {
                    feedService.popularFilter = feedService.popularFilter == .follows ? .all : .follows
                    feedService.recomputeFilteredNotes()
                }) {
                    Image(systemName: feedService.popularFilter == .follows ? "person.2.fill" : "person.2")
                        .font(.appSystem(size: 15, weight: .semibold))
                        .foregroundColor(feedService.popularFilter == .follows ? Color.havenPurple : .secondary)
                }
                .buttonStyle(.plain)
                .help(feedService.popularFilter == .follows ? String(localized: "feed.help.showingFollowsOnly") : String(localized: "feed.help.filterToFollows"))

                // Non-Follows filter
                Button(action: {
                    feedService.popularFilter = feedService.popularFilter == .nonFollows ? .all : .nonFollows
                    feedService.recomputeFilteredNotes()
                }) {
                    Image(systemName: feedService.popularFilter == .nonFollows ? "globe.americas.fill" : "globe.americas")
                        .font(.appSystem(size: 15, weight: .semibold))
                        .foregroundColor(feedService.popularFilter == .nonFollows ? Color.havenPurple : .secondary)
                }
                .buttonStyle(.plain)
                .help(feedService.popularFilter == .nonFollows ? String(localized: "feed.help.showingNonFollowsOnly") : String(localized: "feed.help.filterToNonFollows"))

                // Engagement stats toggle
                Button(action: { feedService.showPopularEngagement.toggle() }) {
                    Image(systemName: feedService.showPopularEngagement ? "chart.bar.fill" : "chart.bar")
                        .font(.appSystem(size: 15, weight: .semibold))
                        .foregroundColor(feedService.showPopularEngagement ? Color.havenPurple : .secondary)
                }
                .buttonStyle(.plain)
                .help(feedService.showPopularEngagement ? String(localized: "feed.help.hideEngagementStats") : String(localized: "feed.help.showEngagementStats"))
            } else {
                // Auto-load new posts
                Button(action: { configService.config.autoLoadNewPosts.toggle(); configService.save() }) {
                    Image(systemName: configService.config.autoLoadNewPosts ? "bolt.circle.fill" : "bolt.circle")
                        .font(.appSystem(size: 15, weight: .semibold))
                        .foregroundColor(configService.config.autoLoadNewPosts ? Color.havenPurple : .secondary)
                }
                .buttonStyle(.plain)
                .help(configService.config.autoLoadNewPosts ? String(localized: "feed.help.autoLoadOn") : String(localized: "feed.help.autoLoadOff"))

                // Reposts toggle
                Button(action: { configService.config.showReposts.toggle(); configService.save(); feedService.recomputeFilteredNotes() }) {
                    Image(systemName: "arrow.2.squarepath")
                        .font(.appSystem(size: 15, weight: .semibold))
                        .foregroundColor(configService.config.showReposts ? Color.havenPurple : .secondary)
                }
                .buttonStyle(.plain)
                .help(configService.config.showReposts ? String(localized: "feed.help.hideReposts") : String(localized: "feed.help.showReposts"))

                // Replies toggle
                Button(action: { configService.config.showReplies.toggle(); configService.save(); feedService.recomputeFilteredNotes() }) {
                    Image(systemName: configService.config.showReplies ? "message.fill" : "message")
                        .font(.appSystem(size: 15, weight: .semibold))
                        .foregroundColor(configService.config.showReplies ? Color.havenPurple : .secondary)
                }
                .buttonStyle(.plain)
                .help(configService.config.showReplies ? String(localized: "feed.help.hideReplies") : String(localized: "feed.help.showReplies"))

                // Divider to separate compact toggle
                Divider()
                    .frame(height: 20)
                    .padding(.horizontal, 8)

                // Compact mode toggle
                Button(action: {
                    toggleCompactModeForCurrentFeed()
                }) {
                    Image(systemName: compactModeEnabledForCurrentFeed ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
                        .font(.appSystem(size: 15, weight: .semibold))
                        .foregroundColor(compactModeEnabledForCurrentFeed ? Color.havenPurple : .secondary)
                }
                .buttonStyle(.plain)
                .help(compactModeEnabledForCurrentFeed ? "Compact view" : "Enable compact view")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.platformSecondaryGroupedBackground)
    }
    #endif

    @ViewBuilder
    private var rootContent: some View {
        ZStack {
            // Match the platform theme background
            Color.platformWindowBackground.ignoresSafeArea()

            Group {
                // Only show the full-screen contact-loading spinner when there
                // are no cached notes to render. Once a snapshot has been
                // restored (or notes have streamed in), the background sync
                // is surfaced via the inline `syncingPill` instead.
                // "You aren't following anyone" is a conclusion, and it needs a
                // finished contact load behind it. Deriving it from the loading
                // flags alone made it true for the first seconds of every
                // launch, before anything had started. FollowingFeedState owns
                // that rule and is unit-tested; the view only asks.
                let isFollowSetFeed = feedService.isFollowSetMode
                    || (feedService.feedMode == .media && feedService.mediaFeedMode == .following)
                let placeholder = FollowingFeedState.decide(
                    followCount: feedService.followedPubkeys.count,
                    hasAttemptedContactLoad: feedService.hasAttemptedContactLoad,
                    isLoadingContacts: feedService.isLoadingContacts,
                    isLoadingFeed: feedService.isLoadingFeed,
                    hasNotes: !feedService.notes.isEmpty
                )
                let showLoadingContacts = isFollowSetFeed && placeholder == .loading
                let showEmptyState = isFollowSetFeed && placeholder == .empty

                if showLoadingContacts {
                    loadingContactsView
                } else if feedService.feedMode == .discovery && feedService.isLoadingExtendedNetwork && feedService.notes.isEmpty {
                    loadingExtendedNetworkView
                } else if feedService.feedMode == .popular && feedService.isLoadingPopular && feedService.notes.isEmpty {
                    loadingPopularView
                } else if showEmptyState {
                    emptyStateView
                } else if feedService.feedMode == .discovery && feedService.extendedNetworkPubkeys.isEmpty && !feedService.isLoadingFeed && !feedService.isLoadingExtendedNetwork {
                    emptyDiscoveryStateView
                } else if feedService.feedMode == .popular && feedService.filteredNotes.isEmpty && !feedService.isLoadingFeed && !feedService.isLoadingPopular {
                    emptyPopularStateView
                } else {
                    feedList
                }
            }
            .transition(.opacity)
            .animation(Motion.fade, value: configService.activeAccountHexPubkey)
        }
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                HStack(spacing: 12) {
                    Button(action: { showingRelayStatus = true }) {
                        Circle()
                            .fill(feedService.connectionDotColor)
                            .frame(width: 10, height: 10)
                            .shadow(color: feedService.connectionDotColor.opacity(0.6), radius: 3)
                    }
                    .buttonStyle(.plain)
                    .frame(width: 30, height: 30)
                    .applyGlassCircle()

                    Menu {
                        ForEach(FeedMode.allCases, id: \.self) { mode in
                            Button(action: { feedService.switchMode(mode) }) {
                                let displayName = mode == .discovery ? "Discover" : mode.rawValue
                                if feedService.feedMode == mode {
                            Label(displayName, systemImage: "checkmark")
                        } else {
                            Text(displayName)
                        }
                            }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            let displayName = feedService.feedMode == .discovery ? "Discover" : feedService.feedMode.rawValue
                            Text(displayName)
                                .font(.appSystem(size: 17, weight: .bold))
                            Image(systemName: "chevron.down")
                                .font(.appSystem(size: 9, weight: .bold))
                        }
                        .foregroundColor(.white)
                    }
                }
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                ViewThatFits {
                    feedTrailingToolbarInline
                    feedTrailingToolbarMenu
                }
            }
        }
        #endif
        .onAppear {
            feedService.markViewed()
            rebuildRowDataCache(immediate: true)
            // Resume if previously paused (e.g. view disappeared while in menu bar).
            if feedService.isPaused {
                feedService.resumeFeed()
                return
            }
            // Wait for relay to be ready before loading feed to avoid OOM
            // from relay + feed + media all starting simultaneously. This covers
            // the case where the relay was ALREADY ready before the view appeared
            // (so FeedService's readiness observer's transition was missed/deduped).
            // Once-ready and follow-set/relay changes after this are driven by
            // FeedService.reconcileFeedSubscriptions via its relay-readiness observer.
            if relayManager.isReadyForConnections && feedService.notes.isEmpty && !feedService.isLoadingContacts {
                feedService.startInitialLoad()
            }
        }
        .sheet(item: $composeContext) { ctx in
            ComposeView(onDismiss: { composeContext = nil }, replyTo: ctx.replyTo, quoteTo: ctx.quoteTo, initialContent: ctx.initialContent, restoredDraftId: ctx.draftId)
                .environmentObject(nostrService)
                .environmentObject(configService)
        }
        .onChange(of: pendingManager.editRequest?.id) { _, _ in
            guard let req = pendingManager.editRequest else { return }
            composeContext = ComposeContext(replyTo: req.replyTo, quoteTo: req.quoteTo, initialContent: req.content, draftId: req.draftId)
            pendingManager.editRequest = nil
        }
        .sheet(isPresented: $showingRelayStatus) {
            FeedDashboardSheet(onDismiss: { showingRelayStatus = false })
                .environmentObject(relayManager)
                .environmentObject(configService)
                .environmentObject(nostrService)
        }
        .sheet(item: Binding<IdentifiableString?>(
            get: { showingNoteId.map { IdentifiableString(id: $0) } },
            set: { showingNoteId = $0?.id }
        )) { noteId in
            NoteDetailViewWrapper(noteId: noteId.id, onDismiss: { showingNoteId = nil })
                .environmentObject(nostrService)
                .environmentObject(configService)
        }
        .sheet(item: $showingProfileKey) { p in
            ProfileView(pubkey: p.id, onDismiss: { showingProfileKey = nil })
                .environmentObject(nostrService)
                .environmentObject(configService)
        }
        .sheet(item: $showingMediaUrl) { media in
            FeedMediaPager(urls: media.allURLs, selected: media.url, onDismiss: { showingMediaUrl = nil })
        }
        .sheet(item: $showingArticle) { route in
            ArticleReaderView(note: route.note)
                .environmentObject(nostrService)
                .frame(minWidth: 520, minHeight: 480)
        }
        .sheet(isPresented: $isShowingGridMediaViewer) {
            ZStack {
                Color.black
                    .opacity(max(0.1, 1.0 - (abs(galleryDragOffset.height) / 500.0)))
                    .ignoresSafeArea()
                
                MediaPagerView(items: gridMediaSnapshot.map { $0.id }, selection: $selectedGridMediaNoteId, enableKeyboardNavigation: true) { noteId in
                    if let note = gridMediaSnapshot.first(where: { $0.id == noteId }), let firstMediaURL = note.mediaURLs.first {
                        FeedMediaViewer(url: firstMediaURL, enableDragDismiss: false, onDismiss: { isShowingGridMediaViewer = false })
                            #if os(iOS)
                            .transition(.opacity.animation(Motion.media))
                            #endif
                    }
                }
                .offset(y: galleryDragOffset.height)
                .scaleEffect(max(0.8, 1.0 - (abs(galleryDragOffset.height) / 1000.0)))
                .gesture(
                    DragGesture()
                        .onChanged { gesture in
                            if abs(gesture.translation.height) > abs(gesture.translation.width) || galleryDragOffset.height != 0 {
                                galleryDragOffset = CGSize(width: 0, height: gesture.translation.height)
                            }
                        }
                        .onEnded { gesture in
                            if abs(galleryDragOffset.height) > 120 {
                                withAnimation(Motion.dismiss) {
                                    isShowingGridMediaViewer = false
                                    galleryDragOffset = .zero
                                }
                            } else {
                                withAnimation(Motion.snapBack) {
                                    galleryDragOffset = .zero
                                }
                            }
                        }
                )
            }
            .ignoresSafeArea()
            .onDisappear {
                selectedGridMediaNoteId = nil
            }
        }
        .alert(String(localized: "feed.alert.sensitiveContent.title"), isPresented: $showingGlobalMediaWarning) {
            Button(String(localized: "feed.alert.sensitiveContent.proceed"), role: .destructive) {
                feedService.mediaFeedMode = .global
                feedService.refresh()
            }
            Button(String(localized: "feed.alert.sensitiveContent.cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "feed.alert.sensitiveContent.message"))
        }
        .alert(String(localized: "feed.alert.sensitiveContent.title"), isPresented: $showingGlobalLiveWarning) {
            Button(String(localized: "feed.alert.sensitiveContent.proceed"), role: .destructive) {
                liveService.setScope(.global)
            }
            Button(String(localized: "feed.alert.sensitiveContent.cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "feed.alert.sensitiveContent.message"))
        }
        .sheet(item: $playingStream) { stream in
            LiveStreamPlayerView(stream: stream, onBlocked: { pubkey in
                liveService.removeStreams(byHost: pubkey)
            })
            .environmentObject(nostrService)
            .environmentObject(configService)
        }
        .alert(String(localized: "feed.alert.sensitiveContent.title"), isPresented: $showingGlobalRecipeWarning) {
            Button(String(localized: "feed.alert.sensitiveContent.proceed"), role: .destructive) {
                recipeService.setScope(.global)
            }
            Button(String(localized: "feed.alert.sensitiveContent.cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "feed.alert.sensitiveContent.message"))
        }
    }

    // MARK: - Loading Contacts

    private var loadingContactsView: some View {
        VStack(spacing: 32) {
            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                    .tint(Color.havenPurple)

                VStack(spacing: 8) {
                    Text(String(localized: "feed.loading.synchronizing"))
                        .font(.appSystem(size: 18, weight: .bold, design: .default))
                        .tracking(0.3)
                    Text(String(localized: "feed.loading.fetchingFollows"))
                        .font(.appSystem(size: 13, weight: .regular, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }

            Text(String(localized: "feed.loading.patience"))
                .font(.appSystem(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.6))
                .tracking(0.5)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.platformControlBackground)
    }

    private var loadingExtendedNetworkView: some View {
        VStack(spacing: 32) {
            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                    .tint(Color.havenPurple)

                VStack(spacing: 8) {
                    Text(String(localized: "feed.loading.analyzingNetwork"))
                        .font(.appSystem(size: 18, weight: .bold, design: .default))
                        .tracking(0.3)
                    Text(String(localized: "feed.loading.findingConnections"))
                        .font(.appSystem(size: 13, weight: .regular, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }

            Text(String(localized: "feed.loading.patience"))
                .font(.appSystem(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.6))
                .tracking(0.5)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.platformControlBackground)
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 40) {
            if relayManager.isBooting {
                // Relay is still starting up
                VStack(spacing: 16) {
                    ProgressView()
                        .controlSize(.large)
                        .tint(Color.havenPurple)

                    VStack(spacing: 12) {
                        Text(String(localized: "feed.empty.relayStarting"))
                            .font(.appSystem(size: 22, weight: .bold, design: .default))
                            .tracking(0.2)

                        Text(relayManager.bootStatusMessage.isEmpty ? String(localized: "feed.empty.initializingRelay") : relayManager.bootStatusMessage)
                            .font(.appSystem(size: 13, weight: .regular, design: .monospaced))
                            .foregroundColor(.secondary)
                            .tracking(0.3)
                            .multilineTextAlignment(.center)
                    }
                }
            } else {
                // Relay is running but no follows
                VStack(spacing: 16) {
                    Image(systemName: "person.crop.circle.badge.plus")
                        .font(.appSystem(size: 56, weight: .thin))
                        .foregroundStyle(
                            LinearGradient(
                                gradient: Gradient(colors: [Color.havenPurple, Color.havenPurpleLight]),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    VStack(spacing: 12) {
                        Text(String(localized: "feed.empty.following.title"))
                            .font(.appSystem(size: 22, weight: .bold, design: .default))
                            .tracking(0.2)

                        Text(String(localized: "feed.empty.following.subtitle"))
                            .font(.appSystem(size: 13, weight: .regular, design: .monospaced))
                            .foregroundColor(.secondary)
                            .tracking(0.3)
                    }
                }

                Button {
                    feedService.refresh()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.clockwise")
                        Text(String(localized: "feed.action.refresh"))
                    }
                    .font(.appSystem(size: 14, weight: .semibold))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        LinearGradient(
                            gradient: Gradient(colors: [Color.havenPurple, Color.havenPurpleLight]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .cornerRadius(10)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(max(16, min(48, 24))) // Adaptive padding
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.platformControlBackground)
    }

    private var emptyDiscoveryStateView: some View {
        VStack(spacing: 40) {
            if relayManager.isBooting {
                // Relay is still starting up
                VStack(spacing: 16) {
                    ProgressView()
                        .controlSize(.large)
                        .tint(Color.havenPurple)

                    VStack(spacing: 12) {
                        Text(String(localized: "feed.empty.relayStarting"))
                            .font(.appSystem(size: 22, weight: .bold, design: .default))
                            .tracking(0.2)

                        Text(relayManager.bootStatusMessage.isEmpty ? String(localized: "feed.empty.initializingRelay") : relayManager.bootStatusMessage)
                            .font(.appSystem(size: 13, weight: .regular, design: .monospaced))
                            .foregroundColor(.secondary)
                            .tracking(0.3)
                            .multilineTextAlignment(.center)
                    }
                }
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "network.badge.shield.half.filled")
                        .font(.appSystem(size: 56, weight: .thin))
                        .foregroundStyle(
                            LinearGradient(
                                gradient: Gradient(colors: [Color.havenPurple, Color.havenPurpleLight]),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    VStack(spacing: 12) {
                        Text(String(localized: "feed.empty.discovery.title"))
                            .font(.appSystem(size: 22, weight: .bold, design: .default))
                            .tracking(0.2)

                        Text(String(localized: "feed.empty.discovery.subtitle"))
                            .font(.appSystem(size: 13, weight: .regular, design: .monospaced))
                            .foregroundColor(.secondary)
                            .tracking(0.3)
                            .multilineTextAlignment(.center)
                    }
                }

                Button {
                    feedService.refresh()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.clockwise")
                        Text(String(localized: "feed.action.refresh"))
                    }
                    .font(.appSystem(size: 14, weight: .semibold))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        LinearGradient(
                            gradient: Gradient(colors: [Color.havenPurple, Color.havenPurpleLight]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .cornerRadius(10)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(max(16, min(48, 24))) // Adaptive padding
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.platformControlBackground)
    }

    // MARK: - Popular Feed States

    private var loadingPopularView: some View {
        VStack(spacing: 32) {
            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                    .tint(Color.havenPurple)

                VStack(spacing: 8) {
                    Text(String(localized: "feed.loading.findingPopular"))
                        .font(.appSystem(size: 18, weight: .bold, design: .default))
                        .tracking(0.3)
                    Text(String(localized: "feed.loading.scoringEngagement"))
                        .font(.appSystem(size: 13, weight: .regular, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }

            Text(String(localized: "feed.loading.analyzingReactions"))
                .font(.appSystem(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.6))
                .tracking(0.5)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.platformControlBackground)
    }

    private var emptyPopularStateView: some View {
        VStack(spacing: 40) {
            VStack(spacing: 16) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.appSystem(size: 56, weight: .thin))
                    .foregroundStyle(
                        LinearGradient(
                            gradient: Gradient(colors: [Color.havenPurple, Color.havenPurpleLight]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                VStack(spacing: 12) {
                    Text(String(localized: "feed.empty.popular.title"))
                        .font(.appSystem(size: 22, weight: .bold, design: .default))
                        .tracking(0.2)

                    Text(String(localized: "feed.empty.popular.subtitle"))
                        .font(.appSystem(size: 13, weight: .regular, design: .monospaced))
                        .foregroundColor(.secondary)
                        .tracking(0.3)
                        .multilineTextAlignment(.center)
                }
            }

            Button {
                feedService.refresh()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.clockwise")
                    Text(String(localized: "feed.action.refresh"))
                }
                .font(.appSystem(size: 14, weight: .semibold))
                .foregroundColor(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    LinearGradient(
                        gradient: Gradient(colors: [Color.havenPurple, Color.havenPurpleLight]),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .cornerRadius(10)
            }
            .buttonStyle(.plain)
        }
        .padding(max(16, min(48, 24)))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.platformControlBackground)
    }

    // MARK: - Engagement Stats Badge

    @ViewBuilder
    private func engagementBadge(score: Double) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "flame.fill")
                .font(.appSystem(size: 9))
                .foregroundColor(.orange)
            Text(formatEngagementScore(score))
                .font(.appSystem(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.9))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(Color.havenPurple.opacity(0.3), lineWidth: 0.5)
        )
    }

    private func formatEngagementScore(_ score: Double) -> String {
        if score >= 1000 {
            return String(format: "%.1fk", score / 1000)
        }
        return String(format: "%.0f", score)
    }

    // MARK: - Row Data Cache

    /// Rebuild the per-row data cache for all currently visible filtered notes.
    /// Called when the underlying data changes (notes, likes, profiles, etc.)
    /// so the ForEach loop can reuse cached values instead of calling resolve()
    /// on every unrelated SwiftUI re-render.
    ///
    /// This method is debounced to prevent expensive synchronous operations
    /// during active scrolling, especially when scrolling to the top triggers
    /// auto-loading of pending notes.
    private func rebuildRowDataCache(immediate: Bool = false) {
        // Cancel any pending rebuild to avoid redundant work
        cacheRebuildWork?.cancel()

        let work = DispatchWorkItem { [self] in
            var newCache: [String: FeedNoteRowData] = [:]
            newCache.reserveCapacity(feedService.filteredNotes.count)
            for note in feedService.filteredNotes {
                newCache[note.id] = FeedNoteRowData.resolve(
                    for: note,
                    feedService: feedService,
                    nostrService: nostrService
                )
            }
            rowDataCache = newCache
        }

        cacheRebuildWork = work

        if immediate {
            // Execute immediately for initial load
            work.perform()
        } else {
            // Use a short delay to batch multiple rapid changes together.
            // During scrolling, this prevents blocking the main thread.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
        }
    }

    // MARK: - Incremental row-data cache updates
    //
    // `rebuildRowDataCache` (above) re-resolves EVERY visible note and is kept
    // only for the initial on-appear build. Steady-state changes (a like, a zap,
    // one profile arriving) used to trigger that full rebuild too — re-resolving
    // up to 800 rows to reflect a one-row change, ~100+ times during boot as
    // profile metadata streams in one pubkey at a time. The handlers below update
    // only the rows that actually changed. `resolve()` is reused verbatim, so the
    // resulting rowData is identical to a full rebuild.

    /// Reconcile the cache against `filteredNotes` after the visible set changes:
    /// keep entries for notes still present, resolve only newly-added notes, drop
    /// removed ones, and repair rows whose parent / reposted-original dependency
    /// has just arrived (the only way an existing row's resolved data can change
    /// without its own id changing). Debounced like the full rebuild.
    private func reconcileRowDataCache() {
        cacheRebuildWork?.cancel()
        let work = DispatchWorkItem { [self] in
            let notes = feedService.filteredNotes
            var newCache: [String: FeedNoteRowData] = [:]
            newCache.reserveCapacity(notes.count)
            for note in notes {
                if let existing = rowDataCache[note.id] {
                    // A previously-unresolved cross-note dependency (the parent
                    // note, or a kind-6 repost's original) may now resolve.
                    let needsParent = note.parentEventId != nil && existing.parentNote == nil
                    let needsOriginal = note.kind == 6 && note.content.isEmpty
                        && note.repostedEventId != nil && existing.resolvedOriginal == nil
                    if needsParent || needsOriginal {
                        newCache[note.id] = FeedNoteRowData.resolve(for: note, feedService: feedService, nostrService: nostrService)
                    } else {
                        newCache[note.id] = existing
                    }
                } else {
                    newCache[note.id] = FeedNoteRowData.resolve(for: note, feedService: feedService, nostrService: nostrService)
                }
            }
            rowDataCache = newCache
        }
        cacheRebuildWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    /// Re-resolve only the cached rows whose id is in `ids`. Reassigns the cache
    /// (triggering a SwiftUI update) only if something actually changed —
    /// `FeedNoteRowData: Equatable` makes that comparison free.
    private func resolveRows(matching ids: Set<String>) {
        guard !ids.isEmpty else { return }
        var updated = rowDataCache
        var didChange = false
        for id in ids {
            guard rowDataCache[id] != nil, let note = feedService.findNote(id: id) else { continue }
            let resolved = FeedNoteRowData.resolve(for: note, feedService: feedService, nostrService: nostrService)
            if updated[id] != resolved {
                updated[id] = resolved
                didChange = true
            }
        }
        if didChange { rowDataCache = updated }
    }

    /// likedEventIds is keyed by `note.id`, so the symmetric difference is exactly
    /// the set of affected rows.
    private func updateRowDataForLikes(old: Set<String>, new: Set<String>) {
        resolveRows(matching: old.symmetricDifference(new))
    }

    /// zappedEventIds is a `[noteID: amount]` dict; collect ids whose amount was
    /// added, removed, or changed.
    private func updateRowDataForZaps(old: [String: Int], new: [String: Int]) {
        var changed = Set<String>()
        for (id, amount) in new where old[id] != amount { changed.insert(id) }
        for id in old.keys where new[id] == nil { changed.insert(id) }
        resolveRows(matching: changed)
    }

    /// repostedEventIds is keyed by `repostCheckId = repostedEventId ?? id`, which
    /// differs from `note.id` for kind-6 repost rows. Map the changed keys back to
    /// the affected row ids with the same expression `resolve()` uses.
    private func updateRowDataForReposts(old: Set<String>, new: Set<String>) {
        let changedKeys = old.symmetricDifference(new)
        guard !changedKeys.isEmpty else { return }
        var ids = Set<String>()
        for note in feedService.filteredNotes {
            let repostCheckId = note.repostedEventId ?? note.id
            if changedKeys.contains(repostCheckId) { ids.insert(note.id) }
        }
        resolveRows(matching: ids)
    }

    /// A batch of profiles changed. Re-resolve only rows that reference any of
    /// those pubkeys as author, displayPubkey, parent author, reposter, or
    /// replyTo — every profile-dependent field `resolve()` reads.
    private func refreshRowsForPubkeys(_ pubkeys: Set<String>) {
        guard !pubkeys.isEmpty else { return }
        var ids = Set<String>()
        for note in feedService.filteredNotes {
            if pubkeys.contains(note.pubkey)
                || (note.repostedBy.map(pubkeys.contains) ?? false)
                || (note.replyToPubkey.map(pubkeys.contains) ?? false) {
                ids.insert(note.id)
                continue
            }
            // parent author
            if let parentId = note.parentEventId,
               let parent = feedService.findNote(id: parentId),
               pubkeys.contains(parent.pubkey) {
                ids.insert(note.id)
                continue
            }
            // kind-6 repost: original author drives displayPubkey/displayProfile
            if note.kind == 6, note.content.isEmpty,
               let refId = note.repostedEventId,
               let original = feedService.findNote(id: refId),
               pubkeys.contains(original.pubkey) {
                ids.insert(note.id)
            }
        }
        resolveRows(matching: ids)
    }

    /// Referenced notes (thread parents, kind-6 originals, quoted notes) just
    /// arrived — re-resolve only the rows that reference them, so the parent
    /// preview replaces its skeleton immediately instead of waiting for an
    /// unrelated change to force a rebuild.
    private func refreshRowsForReferencedNotes(_ arrivedIds: Set<String>) {
        resolveRows(matching: ReferencedNoteRepair.rowsNeedingRepair(
            notes: feedService.filteredNotes, arrivedIds: arrivedIds))
    }

    /// noteStats changed — re-resolve rows whose stats actually differ.
    private func updateRowDataForNoteStats(old: [String: NoteStats], new: [String: NoteStats]) {
        var changed = Set<String>()
        for (id, stats) in new where old[id] != stats { changed.insert(id) }
        resolveRows(matching: changed)
    }

    // MARK: - Auto-load debounce

    /// Schedules a debounced `applyPendingNotes()` call, cancelling any
    /// previously pending call so only one fires at a time.
    private func scheduleAutoLoad(delay: Double) {
        autoLoadWork?.cancel()
        let work = DispatchWorkItem { [self] in
            guard !feedService.pendingNotes.isEmpty,
                  configService.config.autoLoadNewPosts,
                  isAtTop else { return }
            feedService.applyPendingNotes()
        }
        autoLoadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - Feed Actions (environment for FeedNoteRow)

    private var feedActionsValue: FeedActions {
        .make(feedService: feedService, nostrService: nostrService)
    }

    // MARK: - Feed List

    /// Articles feed: long-form events from the follow set, already synced to
    /// the device's own relay by the normal feed sync, rendered as cards
    /// instead of as notes.
    @ViewBuilder
    private var articleListView: some View {
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
            Text("Long-form posts from people you follow show up here. Nothing to read yet.")
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
    private var recipeGridView: some View {
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
                Button("Show everyone's recipes") { showingGlobalRecipeWarning = true }
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

    /// Live streams: NIP-53 events that are running *and* carry a URL Apple's
    /// player can open. Never cached — a stream is only interesting while it is
    /// live, and a saved one is a gravestone.
    @ViewBuilder
    private var liveGridView: some View {
        VStack(spacing: 12) {
            if liveService.isLoading && liveService.streams.isEmpty {
                ProgressView()
                    .controlSize(.large)
                    .tint(Color.havenPurple)
                    .padding(.vertical, 60)
            } else if liveService.streams.isEmpty {
                emptyLiveStateView
            } else {
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

    private var emptyLiveStateView: some View {
        VStack(spacing: 10) {
            Image(systemName: liveService.loadFailed ? "wifi.slash" : "dot.radiowaves.left.and.right")
                .font(.appSystem(size: 34))
                .foregroundColor(.havenPurple.opacity(0.7))
            Text(emptyLiveTitle)
                .font(.appSystem(size: 16, weight: .bold))
            Text(emptyLiveMessage)
                .font(.appSystem(size: 13))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            if liveService.followSetIsEmpty {
                Button("Show everyone's streams") { showingGlobalLiveWarning = true }
                    .buttonStyle(.borderless)
                    .foregroundColor(.havenPurple)
                    .padding(.top, 4)
            } else {
                Button("Try again") { liveService.refresh() }
                    .buttonStyle(.borderless)
                    .foregroundColor(.havenPurple)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 60)
    }

    private var emptyLiveTitle: String {
        if liveService.followSetIsEmpty { return "Nobody you follow is live" }
        return liveService.loadFailed ? "Could not reach any relay" : "Nothing live right now"
    }

    private var emptyLiveMessage: String {
        if liveService.followSetIsEmpty {
            return "Switch to Global to see everyone who is streaming."
        }
        return liveService.loadFailed
            ? "Live streams come from other people's relays, so this one needs a connection."
            : "Most stream announcements on Nostr are for streams that already ended. Only running ones show here."
    }

    private var feedList: some View {
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
                            #else
                            let isExpanded = (expandedNoteId == note.id)
                            feedNoteRowContent(note: note, profile: profile, rowData: rowData, parentIsNext: parentIsNext, isExpanded: isExpanded)
                                .onTapGesture {
                                    // On macOS in full mode, open note detail
                                    if !isCompactModeActive {
                                        showingNoteId = note.id
                                    }
                                }
                            #endif
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
                }
                .refreshable {
                    isRefreshing = true
                    feedService.refresh()
                    // Hold the indicator until loading finishes
                    while feedService.isLoadingFeed {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                    isRefreshing = false
                }
                .tint(Color.secondary.opacity(0.6))
                .scrollPosition(id: $scrolledNoteID)
                .scrollDirectionTracking(feedService: feedService, isAtTop: $isAtTop)
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
                .onChange(of: feedService.pendingNotes.count) { _, count in
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
                    if atTop && configService.config.autoLoadNewPosts && !feedService.pendingNotes.isEmpty && !feedService.isLoadingFeed {
                        scheduleAutoLoad(delay: 0.5)
                    }
                }
                .modifier(RowDataCacheObservers(
                    feedService: feedService,
                    nostrService: nostrService,
                    onFiltered: { reconcileRowDataCache() },
                    onLikes: { updateRowDataForLikes(old: $0, new: $1) },
                    onReposts: { updateRowDataForReposts(old: $0, new: $1) },
                    onZaps: { updateRowDataForZaps(old: $0, new: $1) },
                    onProfiles: { refreshRowsForPubkeys($0) },
                    onFollowsChanged: { rebuildRowDataCache() },
                    onNoteStats: { updateRowDataForNoteStats(old: $0, new: $1) }
                ))
                .modifier(ReferencedNoteObserver(
                    feedService: feedService,
                    onReferencedNotes: { refreshRowsForReferencedNotes($0) }
                ))

                // Floating "New Posts" indicator — shown when auto-load is off,
                // or when auto-load is on but the user has scrolled down.
                if !feedService.pendingNotes.isEmpty && (!configService.config.autoLoadNewPosts || !isAtTop) {
                    Button(action: {
                        feedService.applyPendingNotes()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            withAnimation(Motion.scrollJump) {
                                proxy.scrollTo("top", anchor: .top)
                            }
                        }
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.up")
                                .font(.appSystem(size: 12, weight: .bold))
                            Text("\(feedService.pendingNotes.count) New Posts")
                                .font(.appSystem(size: 13, weight: .bold))
                        }
                        .padding(.vertical, 10)
                        .padding(.horizontal, 20)
                        .background(
                            Capsule()
                                .fill(Color.havenPurple)
                                .shadow(color: Color.black.opacity(0.4), radius: 8, x: 0, y: 4)
                        )
                        .foregroundColor(.white)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(feedService.pendingNotes.count) new posts, tap to load")
                    .padding(.top, 12)
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
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
                rebuildRowDataCache()
                withAnimation(Motion.scrollJump) {
                    proxy.scrollTo("top", anchor: .top)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .composeFromTabBar)) { note in
                guard (note.object as? Int) == 0 else { return }
                composeContext = ComposeContext(replyTo: nil, quoteTo: nil)
            }
        }
        .overlay {
            if configService.isSwitchingAccount {
                Color.black.opacity(0.15)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(Motion.fade, value: configService.isSwitchingAccount)
        .overlay(alignment: .bottomTrailing) {
            #if os(iOS)
            if !feedService.feedScrollingDown {
                Button {
                    composeContext = ComposeContext(replyTo: nil, quoteTo: nil)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.pencil")
                            .font(.appSystem(size: 15, weight: .bold))
                        Text(String(localized: "feed.action.post"))
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
                .accessibilityLabel("Compose new post")
                .padding(.trailing, 20)
                .padding(.bottom, 90)
                .hoverEffect(.lift)
                .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
            #endif
        }
        .animation(Motion.chrome, value: feedService.feedScrollingDown)
    }

    private var mediaGridView: some View {
        Group {
            let filteredNotes = feedService.filteredMediaNotes

            if filteredNotes.isEmpty && !feedService.isLoadingFeed {
                VStack(spacing: 20) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.appSystem(size: 56, weight: .thin))
                        .foregroundStyle(
                            LinearGradient(
                                gradient: Gradient(colors: [Color.havenPurple, Color.havenPurpleLight]),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Text(String(localized: "feed.media.empty.title"))
                        .font(.appSystem(size: 18, weight: .bold))
                        .foregroundColor(.white)
                    Text(feedService.mediaFeedMode == .following ? String(localized: "feed.media.empty.following") : String(localized: "feed.media.empty.global"))
                        .font(.appSystem(size: 13, weight: .regular, design: .monospaced))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: 400)
            } else {
                let columns = [
                    GridItem(.flexible(), spacing: 2),
                    GridItem(.flexible(), spacing: 2),
                    GridItem(.flexible(), spacing: 2)
                ]

                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(filteredNotes) { note in
                        if let firstMediaURL = note.mediaURLs.first {
                            gridCell(for: note, url: firstMediaURL)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    gridMediaSnapshot = filteredNotes
                                    selectedGridMediaNoteId = note.id
                                    isShowingGridMediaViewer = true
                                }
                                .onLongPressGesture(minimumDuration: 0.5) {
                                    showingNoteId = note.id
                                }
                        }
                    }
                }
                .padding(.horizontal, 2)
                
                // Show "Show earlier" button for pagination
                if !filteredNotes.isEmpty {
                    Button {
                        feedService.loadMore()
                    } label: {
                        HStack(spacing: 8) {
                            if feedService.isLoadingFeed {
                                ProgressView().controlSize(.small).tint(Color.havenPurple)
                            } else {
                                Image(systemName: "chevron.down")
                                    .font(.appSystem(size: 12, weight: .semibold))
                            }
                            Text(feedService.isLoadingFeed ? String(localized: "feed.loading.indicator") : String(localized: "feed.media.showEarlier"))
                                .font(.appSystem(size: 12, weight: .semibold, design: .monospaced))
                        }
                        .foregroundColor(.secondary)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                        .background(Color.platformTertiaryGroupedBackground)
                        .cornerRadius(10)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.platformSeparator, lineWidth: 1))
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                    }
                    .buttonStyle(.plain)
                    .disabled(feedService.isLoadingFeed)
                }
                
                Color.clear.frame(height: 80) // Space for floating button
            }
        }
    }

    private func gridCell(for note: FeedNote, url: URL) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .topTrailing) {
                FeedMediaView(url: url, isThumbnail: true)
                    .frame(width: geo.size.width, height: geo.size.width)
                    .clipped()

                // Indicators overlay
                HStack(spacing: 4) {
                    if note.mediaURLs.count > 1 {
                        Image(systemName: "square.fill.on.square.fill")
                            .font(.appSystem(size: 10, weight: .bold))
                            .foregroundColor(.white)
                            .padding(4)
                            .background(Color.black.opacity(0.6))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    } else if let extensionType = FeedMediaType.fromExtension(url), extensionType == .video {
                        Image(systemName: "play.fill")
                            .font(.appSystem(size: 10, weight: .bold))
                            .foregroundColor(.white)
                            .padding(4)
                            .background(Color.black.opacity(0.6))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
                .padding(6)
            }
        }
        .aspectRatio(1, contentMode: .fill)
    }
}

// MARK: - Liquid Glass Modifier

private struct LiquidGlassModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, macOS 26, *) {
            content.glassEffect(.regular, in: .capsule)
        } else {
            content
                .background {
                    ZStack {
                        Capsule().fill(.ultraThinMaterial)
                        Capsule().fill(Color.havenPurple.opacity(0.06))
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.12), Color.clear],
                                    startPoint: .top,
                                    endPoint: .center
                                )
                            )
                    }
                }
                .overlay(
                    Capsule()
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.white.opacity(0.25), Color.white.opacity(0.08)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.5
                        )
                )
        }
    }
}

private struct LiquidGlassVerticalModifier: ViewModifier {
    private let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

    func body(content: Content) -> some View {
        if #available(iOS 26, macOS 26, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: 14))
        } else {
            content
                .background {
                    ZStack {
                        shape.fill(.ultraThinMaterial)
                        shape.fill(Color.havenPurple.opacity(0.06))
                        shape
                            .fill(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.12), Color.clear],
                                    startPoint: .top,
                                    endPoint: .center
                                )
                            )
                    }
                }
                .overlay(
                    shape
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.white.opacity(0.25), Color.white.opacity(0.08)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.5
                        )
                )
        }
    }
}

// MARK: - FeedNoteRow

struct FeedNoteRow: View {
    let note: FeedNote
    let profile: FeedProfile?
    let rowData: FeedNoteRowData
    var onReply: (() -> Void)? = nil
    var onQuote: (() -> Void)? = nil
    var onProfile: ((String) -> Void)? = nil
    var onMedia: ((URL, [URL]) -> Void)? = nil
    var showParent: Bool = true
    var isReplyToNext: Bool = false
    var layoutMode: NoteLayoutMode = .sideBySide
    var isFocused: Bool = false
    var suppressCardStyling: Bool = false

    // Zero ObservableObject subscriptions — all data comes via rowData/actions
    @Environment(\.feedActions) private var actions

    @State private var showingEmojiPicker = false
    @State private var showLightning = false
    @State private var zapSheetContext: ZapSheetContext?
    @State private var showingDeleteConfirm = false
    @State private var showingBroadcastSheet = false
    @State private var showingNoteIdInRow: String?
    @State private var noLightningAddressAlert = false
    @State private var showingUserMenu = false
    @State private var menuExpanded = false
    @State private var showingParentUserMenu = false
    @State private var parentMenuExpanded = false
    @State private var repostPulse = false
    @State private var likePulse = false
    @State private var zapPulse = false
    @State private var parentFetchStartedAt: Date? = nil
    @State private var parentFetchFailed = false
    @State private var parentSkeletonShimmer = false

    var useCompactMode: Bool = false // Whether compact mode is active for this feed type
    var isExpanded: Bool = false // Whether this specific note is expanded
    var onTapRow: (() -> Void)? = nil

    // MARK: - Compact Layout

    @ViewBuilder
    private var compactLayout: some View {
        HStack(alignment: .top, spacing: 8) {
            // Avatar (32x32)
            AvatarView(url: rowData.displayProfile?.pictureURL, pubkey: rowData.displayPubkey)
                .frame(width: 32, height: 32)
                .onTapGesture { onProfile?(rowData.displayPubkey) }

            // Content (flexible)
            VStack(alignment: .leading, spacing: 2) {
                // Header row
                HStack(spacing: 4) {
                    Text(rowData.displayProfile?.bestName ?? shortKey(rowData.displayPubkey))
                        .font(.appSystem(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    if let dp = rowData.displayProfile, let nip05 = dp.nip05, !nip05.isEmpty {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.appSystem(size: 9))
                            .foregroundColor(Color(red: 0.2, green: 0.8, blue: 0.6))
                    }

                    Text("· \(relativeTime(note.createdAt))")
                        .font(.appSystem(size: 11))
                        .foregroundColor(.secondary)

                    Spacer()

                    // Reply/Repost indicators
                    if note.isReply {
                        Image(systemName: "arrowshape.turn.up.left.fill")
                            .font(.appSystem(size: 10))
                            .foregroundColor(Color.havenPurple.opacity(0.7))
                    }
                    if note.repostedBy != nil {
                        Image(systemName: "arrow.2.squarepath")
                            .font(.appSystem(size: 10))
                            .foregroundColor(.green.opacity(0.7))
                    }
                }

                // Truncated content (3 lines max)
                let contentToShow: String = {
                    if note.kind == 6 && note.content.isEmpty, let original = rowData.resolvedOriginal {
                        return original.content
                    }
                    return note.content
                }()

                if !contentToShow.isEmpty {
                    Text(NostrContentFormatter.resolveMentionsPlainText(contentToShow))
                        .font(.appSystem(size: 14))
                        .foregroundColor(.white)
                        .lineLimit(3)
                        .lineSpacing(1)
                }

                // Compact engagement stats
                if (rowData.stats.reactions > 0 && !rowData.zapsOnlyMode) || rowData.stats.reposts > 0 {
                    HStack(spacing: 6) {
                        if rowData.stats.reactions > 0 && !rowData.zapsOnlyMode {
                            HStack(spacing: 1) {
                                Text("❤️").font(.appSystem(size: 9))
                                Text("\(rowData.stats.reactions)")
                                    .font(.appSystem(size: 8, weight: .bold, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }
                        if rowData.stats.reposts > 0 {
                            HStack(spacing: 1) {
                                Image(systemName: "arrow.2.squarepath")
                                    .font(.appSystem(size: 7, weight: .bold))
                                    .foregroundColor(.green)
                                Text("\(rowData.stats.reposts)")
                                    .font(.appSystem(size: 8, weight: .bold, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(.top, 2)
                }
            }

            Spacer(minLength: 8)

            // Media thumbnail (60x60)
            if let firstMedia = note.mediaURLs.first ?? rowData.resolvedOriginal?.mediaURLs.first {
                ZStack(alignment: .bottomTrailing) {
                    FeedMediaView(
                        url: firstMedia,
                        isThumbnail: true
                    )
                    .frame(width: 80, height: 80)
                    .aspectRatio(1, contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                    // Multi-media badge
                    let totalMedia = note.mediaURLs.count + (rowData.resolvedOriginal?.mediaURLs.count ?? 0)
                    if totalMedia > 1 {
                        Text("+\(totalMedia - 1)")
                            .font(.appSystem(size: 10, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.black.opacity(0.7))
                            .clipShape(Capsule())
                            .padding(4)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            ZStack {
                Color.platformSecondaryGroupedBackground
                Color.havenPurple.opacity(0.015)
            }
        )
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    Color.havenPurple.opacity(ConfigService.shared.config.useOLED ? 0.30 : 0.15),
                    lineWidth: ConfigService.shared.config.useOLED ? 1.0 : 0.5
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onTapRow?()
        }
    }

    // MARK: - Full Layout

    @ViewBuilder
    private var fullLayout: some View {
        VStack(alignment: .leading, spacing: 10) {
            // [Existing body content will be extracted here]
            fullLayoutContent
        }
        .foregroundColor(Color(red: 1, green: 1, blue: 1))
        .if(!suppressCardStyling) { view in
            view
                .padding(14)
                .background(
                    ZStack {
                        Color.platformSecondaryGroupedBackground
                        Color.havenPurple.opacity(0.015)
                    }
                )
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(
                            isFocused
                                ? Color.havenPurple
                                : Color.havenPurple.opacity(ConfigService.shared.config.useOLED ? (note.isReply ? 0.40 : 0.30) : (note.isReply ? 0.15 : 0.06)),
                            lineWidth: isFocused ? 2.0 : (ConfigService.shared.config.useOLED ? 1.5 : (note.isReply ? 0.8 : 0.5))
                        )
                )
                .shadow(color: isFocused ? Color.havenPurple.opacity(0.35) : Color.clear, radius: isFocused ? 8 : 0)
                .contentShape(RoundedRectangle(cornerRadius: 12))
                #if os(iOS)
                .hoverEffect(.lift)
                #endif
                .clipped()
        }
    }

    @ViewBuilder
    private var fullLayoutContent: some View {
        // Threading View: Parent Note Preview (shows above the current note)
        if showParent, let pId = note.parentEventId {
            if let parent = rowData.parentNote {
                NoteNavigationLink(note: parent) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(spacing: 0) {
                            AvatarView(url: rowData.parentProfile?.pictureURL, pubkey: parent.pubkey)
                                .frame(width: 40, height: 40)
                                .onTapGesture { toggleParentUserMenu() }

                            if showingParentUserMenu {
                                parentUserMenuToolbar
                            }

                            Rectangle()
                                .fill(Color.havenPurple.opacity(0.3))
                                .frame(width: 2)
                                .frame(maxHeight: .infinity)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(rowData.parentProfile?.bestName ?? shortKey(parent.pubkey))
                                    .font(.appSystem(size: 14, weight: .semibold, design: .default))
                                    .foregroundColor(Color(red: 0.85, green: 0.85, blue: 0.85))
                                    .lineLimit(1)
                                    .onTapGesture { onProfile?(parent.pubkey) }

                                if let pp = rowData.parentProfile, let nip05 = pp.nip05, !nip05.isEmpty {
                                    Image(systemName: "checkmark.seal.fill")
                                        .font(.appCaption2)
                                        .foregroundColor(Color(red: 0.2, green: 0.8, blue: 0.6))
                                }

                                Spacer()

                                Text(relativeTime(parent.createdAt))
                                    .font(.appSystem(size: 11, weight: .regular, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .tracking(0.2)
                            }
                            .padding(.top, 4)

                            let parentFormatted = NostrContentFormatter.format(parent.content, mediaURLs: parent.mediaURLs)
                            if !parentFormatted.characters.isEmpty {
                                Text(parentFormatted)
                                    .font(.appSystem(size: 14, weight: .regular))
                                    .foregroundColor(Color(red: 0.7, green: 0.7, blue: 0.7))
                                    .lineLimit(2)
                            }

                            if !parent.mediaURLs.isEmpty {
                                FeedMediaView(
                                    url: parent.mediaURLs[0],
                                    maxHeight: 150,
                                    portraitMaxHeight: 200,
                                    isThumbnail: false
                                )
                                .frame(maxWidth: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .allowsHitTesting(false)
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
                .fixedSize(horizontal: false, vertical: true)
            } else if parentFetchFailed {
                // The parent never arrived — likely not on any connected relay.
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.appSystem(size: 12, weight: .regular))
                        .foregroundColor(.secondary)
                    Text("Could not load original note")
                        .font(.appSystem(size: 13, weight: .regular))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Retry") {
                        parentFetchFailed = false
                        parentFetchStartedAt = nil
                        actions.retryMissingNote(pId)
                        scheduleParentFetchTimeout(pId)
                    }
                    .font(.appSystem(size: 13, weight: .semibold))
                    .foregroundColor(.havenPurple)
                }
                .padding(.vertical, 6)
            } else {
                // Skeleton while parent is being fetched
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 0) {
                        Circle()
                            .fill(Color.platformTertiaryGroupedBackground)
                            .frame(width: 40, height: 40)
                        Rectangle()
                            .fill(Color.havenPurple.opacity(0.3))
                            .frame(width: 2)
                            .frame(maxHeight: .infinity)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.platformTertiaryGroupedBackground)
                                .frame(width: 80, height: 12)
                            Spacer()
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.platformTertiaryGroupedBackground)
                                .frame(width: 40, height: 10)
                        }
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.platformTertiaryGroupedBackground)
                            .frame(width: 180, height: 12)
                    }
                    .padding(.top, 4)
                }
                .fixedSize(horizontal: false, vertical: true)
                .opacity(parentSkeletonShimmer ? 0.5 : 1.0)
                .animation(Motion.shimmer, value: parentSkeletonShimmer)
                .onAppear {
                    if Motion.shimmer != nil { parentSkeletonShimmer = true }
                    actions.fetchMissingNote(pId)
                    scheduleParentFetchTimeout(pId)
                }
            }
        }

        // Repost indicator
        if note.repostedBy != nil {
            HStack(spacing: 4) {
                Image(systemName: "arrow.2.squarepath")
                    .font(.appSystem(size: 10, weight: .semibold))
                Text("\(rowData.reposterName ?? shortKey(note.repostedBy!)) reposted")
                    .font(.appSystem(size: 11, weight: .medium))
            }
            .foregroundColor(.green.opacity(0.7))
            .padding(.leading, 52)
        }

        // Main Note Content
        let displayPubkey = rowData.displayPubkey

        if layoutMode == .wide {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 6) {
                        AvatarView(url: rowData.displayProfile?.pictureURL, pubkey: displayPubkey)
                            .frame(width: 40, height: 40)
                            .onTapGesture { toggleUserMenu() }
                        if showingUserMenu {
                            userMenuToolbar
                        }
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(rowData.displayProfile?.bestName ?? shortKey(displayPubkey))
                                .font(.appSystem(size: 14, weight: .semibold, design: .default))
                                .foregroundColor(Color(red: 1, green: 1, blue: 1))
                                .lineLimit(1)
                                .onTapGesture { onProfile?(displayPubkey) }

                            if let dp = rowData.displayProfile, let nip05 = dp.nip05, !nip05.isEmpty {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.appCaption2)
                                    .foregroundColor(Color(red: 0.2, green: 0.8, blue: 0.6))
                            }

                            Spacer()

                            Text(relativeTime(note.createdAt))
                                .font(.appSystem(size: 11, weight: .regular, design: .monospaced))
                                .foregroundColor(.secondary)
                                .tracking(0.2)
                        }

                        // Reply indicator - subtle
                        if note.isReply {
                            HStack(spacing: 3) {
                                Image(systemName: "arrowshape.turn.up.left.fill")
                                    .font(.appSystem(size: 9, weight: .semibold))
                                    .foregroundColor(Color.havenPurple.opacity(0.6))

                                if let rPubkey = note.replyToPubkey {
                                    let name = rowData.replyToName ?? shortKey(rPubkey)
                                    Text("reply to \(name)")
                                        .font(.appSystem(size: 10, weight: .regular, design: .monospaced))
                                        .foregroundColor(.secondary.opacity(0.7))
                                        .tracking(0.1)
                                        .onAppear {
                                            if rowData.replyToName == nil {
                                                actions.fetchMissingProfiles([rPubkey])
                                            }
                                        }
                                }
                            }
                        }
                    }
                }

                noteBodyContent
            }
        } else {
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 0) {
                    if note.parentEventId != nil && rowData.parentNote != nil {
                        Rectangle()
                            .fill(Color.havenPurple.opacity(0.3))
                            .frame(width: 2, height: 10)
                    }

                    AvatarView(url: rowData.displayProfile?.pictureURL, pubkey: displayPubkey)
                        .frame(width: 40, height: 40)
                        .onTapGesture { toggleUserMenu() }

                    if showingUserMenu {
                        userMenuToolbar
                    }

                    if isReplyToNext {
                        Rectangle()
                            .fill(Color.havenPurple.opacity(0.3))
                            .frame(width: 2)
                            .frame(maxHeight: .infinity)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(rowData.displayProfile?.bestName ?? shortKey(displayPubkey))
                            .font(.appSystem(size: 14, weight: .semibold, design: .default))
                            .foregroundColor(Color(red: 1, green: 1, blue: 1))
                            .lineLimit(1)
                            .onTapGesture { onProfile?(displayPubkey) }

                        if let dp = rowData.displayProfile, let nip05 = dp.nip05, !nip05.isEmpty {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.appCaption2)
                                .foregroundColor(Color(red: 0.2, green: 0.8, blue: 0.6))
                        }

                        Spacer()

                        Text(relativeTime(note.createdAt))
                            .font(.appSystem(size: 11, weight: .regular, design: .monospaced))
                            .foregroundColor(.secondary)
                            .tracking(0.2)
                    }
                    .padding(.top, 4)

                    // Reply indicator - subtle
                    if note.isReply {
                        HStack(spacing: 3) {
                            Image(systemName: "arrowshape.turn.up.left.fill")
                                .font(.appSystem(size: 9, weight: .semibold))
                                .foregroundColor(Color.havenPurple.opacity(0.6))

                            if let rPubkey = note.replyToPubkey {
                                let name = rowData.replyToName ?? shortKey(rPubkey)
                                Text("reply to \(name)")
                                    .font(.appSystem(size: 10, weight: .regular, design: .monospaced))
                                    .foregroundColor(.secondary.opacity(0.7))
                                    .tracking(0.1)
                                    .onAppear {
                                        if rowData.replyToName == nil {
                                            actions.fetchMissingProfiles([rPubkey])
                                        }
                                    }
                            }
                        }
                    }

                    noteBodyContent
                }
            }
        }
    }

    /// The event whose body this row draws: for an empty-content repost that is
    /// the reposted original, everywhere else the note itself.
    ///
    /// The quote cards have to come from the same event as the text. Reading
    /// them off the kind 6 wrapper — whose content is empty, so it quotes
    /// nothing — made a repost of a quote-post show the reposted text with its
    /// reference stripped and no card underneath.
    private var bodySource: FeedNote {
        if note.kind == 6 && note.content.isEmpty, note.repostedEventId != nil,
           let original = rowData.resolvedOriginal {
            return original
        }
        return note
    }

    /// True while an empty-content repost is waiting for the note it reposted.
    private var isWaitingForRepostedNote: Bool {
        note.kind == 6 && note.content.isEmpty && note.repostedEventId != nil
            && rowData.resolvedOriginal == nil
    }

    @ViewBuilder
    private var noteBodyContent: some View {
        // Content Body — for empty-content reposts this is the reposted note.
        if isWaitingForRepostedNote {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text(String(localized: "feed.note.loadingRepost"))
                    .font(.appSystem(size: 13))
                    .foregroundColor(.secondary)
            }
            .padding(.top, 4)
        } else {
            let formattedContent = NostrContentFormatter.format(bodySource.content, mediaURLs: bodySource.mediaURLs)
            VStack(alignment: .leading, spacing: 8) {
                Text(formattedContent)
                    .font(.appSystem(size: 17, weight: .regular, design: .default))
                    .foregroundColor(Color(red: 1, green: 1, blue: 1))
                    .lineSpacing(2)
                    .lineLimit(nil)
                    .textSelection(.enabled)
            }
            .padding(.top, 4)

            // Media previews
            if !bodySource.mediaURLs.isEmpty {
                feedMediaCarousel(urls: bodySource.mediaURLs)
                    .padding(.top, 4)
            }

            // Link Preview
            if !bodySource.linkURLs.isEmpty {
                LinkPreviewCard(url: bodySource.linkURLs[0])
                    .padding(.top, 4)
            }
        }

        // Quoted Notes
        if !bodySource.quotedEventIds.isEmpty {
            VStack(spacing: 8) {
                ForEach(bodySource.quotedEventIds, id: \.self) { quoteId in
                    if let quotedNote = actions.findNote(quoteId) {
                        NoteNavigationLink(note: quotedNote) {
                            QuotedNoteView(note: quotedNote)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Color.clear
                            .frame(height: 0)
                            .onAppear {
                                actions.fetchMissingNote(quoteId)
                            }
                    }
                }
            }
            .padding(.top, 4)
        }


        // Actions row - minimal and clean
        HStack(spacing: 12) {
            actionButton(icon: "message", action: { onReply?() })
                .accessibilityLabel("Reply")

            actionButton(
                icon: "arrow.2.squarepath",
                color: rowData.isReposted ? .green : .secondary,
                action: {
                    actions.repostNote(note)
                    Motion.firePulse($repostPulse)
                }
            )
            .accessibilityLabel(rowData.isReposted ? "Reposted" : "Repost")
            .scaleEffect(repostPulse ? Motion.pulseScale : 1.0)
            .animation(Motion.pop, value: repostPulse)

            actionButton(icon: "quote.closing", action: { onQuote?() })
                .accessibilityLabel("Quote")

            if !rowData.zapsOnlyMode {
                actionButton(
                    icon: rowData.isLiked ? "heart.fill" : "heart",
                    color: rowData.isLiked ? .red : .secondary,
                    action: { toggleLike() }
                )
                .accessibilityLabel(rowData.isLiked ? "Unlike" : "Like")
                .scaleEffect(likePulse ? Motion.pulseScale : 1.0)
                .animation(Motion.pop, value: likePulse)
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.5)
                        .onEnded { _ in
                            #if os(iOS)
                            let generator = UIImpactFeedbackGenerator(style: .medium)
                            generator.impactOccurred()
                            #endif
                            showingEmojiPicker = true
                        }
                )
                .popover(isPresented: $showingEmojiPicker) {
                    EmojiPickerView { emoji in
                        actions.reactToNote(note, emoji)
                    }
                    #if os(iOS)
                    .presentationDetents([.height(520)])
                    #endif
                }
            }

            if rowData.hasNWC {
                let lud16 = actions.getLightningAddress(note.pubkey)
                let isZapped = rowData.zapAmount != nil
                let hasLightning = lud16 != nil
                Image(systemName: isZapped ? "bolt.fill" : "bolt")
                    .font(.appSystem(size: 14, weight: .medium))
                    .foregroundColor(isZapped ? .orange : (hasLightning ? .secondary : .secondary.opacity(0.35)))
                    .frame(width: 32, height: 32)
                    .background(isZapped ? Color.orange.opacity(0.2) : Color.secondary.opacity(0.1))
                    .clipShape(Capsule())
                    .scaleEffect(zapPulse ? Motion.pulseScale : 1.0)
                    .animation(Motion.pop, value: zapPulse)
                    .contentShape(Capsule())
                    .accessibilityLabel(isZapped ? "Zapped" : "Zap")
                    .accessibilityHint(hasLightning ? "Tap to send sats" : "No lightning address")
                    .onLongPressGesture {
                        if hasLightning {
                            #if os(iOS)
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            #endif
                            zapSheetContext = ZapSheetContext(defaultAmount: rowData.defaultZapAmount / 1000)
                        }
                    }
                    .onTapGesture {
                        if let lud16 = lud16 {
                            Task {
                                let sent = await actions.zapNote(note, lud16, nil)
                                if sent { Motion.firePulse($zapPulse) }
                            }
                            showLightning = true
                        } else {
                            noLightningAddressAlert = true
                        }
                    }
            }

            ShareLink(
                item: URL(string: "https://mynostrspace.com/thread/\(note.nevent)")!,
                subject: Text(String(localized: "feed.share.subject")),
                message: Text(String(localized: "feed.share.message"))
            ) {
                Image(systemName: "square.and.arrow.up")
                    .font(.appSystem(size: 14, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 32, height: 32)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(Capsule())
            }

            Button {
                showingBroadcastSheet = true
            } label: {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.appSystem(size: 14, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 32, height: 32)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .padding(.top, 4)
    }

    var body: some View {
        Group {
            if useCompactMode {
                // Compact mode is active for this feed - show compact or expanded based on state
                if isExpanded {
                    fullLayout
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.95)),
                            removal: .opacity
                        ))
                } else {
                    compactLayout
                        .transition(.opacity)
                }
            } else {
                // Compact mode not active - always show full layout
                fullLayout
            }
        }
        .animation(Motion.panel, value: isExpanded)
        .onAppear {
            // Fetch referenced notes only when this row becomes visible (lazy).
            if note.isReply, let parentId = note.parentEventId, rowData.parentNote == nil {
                actions.fetchMissingNote(parentId)
            }
            if note.kind == 6, note.content.isEmpty,
               let refId = note.repostedEventId, rowData.resolvedOriginal == nil {
                actions.fetchMissingNote(refId)
            }
            for qId in note.quotedEventIds where actions.findNote(qId) == nil {
                actions.fetchMissingNote(qId)
            }
        }
        .overlay {
            LightningAnimationView(isAnimating: $showLightning)
                .allowsHitTesting(false)
        }
        .sheet(item: $zapSheetContext) { context in
            CustomZapSheet(defaultAmount: context.defaultAmount) { amount in
                if let lud16 = actions.getLightningAddress(note.pubkey) {
                    Task {
                        let sent = await actions.zapNote(note, lud16, amount)
                        if sent { Motion.firePulse($zapPulse) }
                    }
                    showLightning = true
                }
            }
            #if os(iOS)
            .presentationDetents([.height(380), .medium])
            .presentationDragIndicator(.visible)
            .presentationBackground(Color.platformWindowBackground)
            #endif
        }
        .environment(\.openURL, OpenURLAction { url in
            if url.scheme == "nostr" {
                let identifier = url.absoluteString.replacingOccurrences(of: "nostr:", with: "")
                if identifier.hasPrefix("npub1") || identifier.hasPrefix("nprofile1") {
                    if let decoded = Bech32.decode(identifier) {
                        onProfile?(decoded.hexString)
                    } else {
                        onProfile?(identifier)
                    }
                    return .handled
                }
                if identifier.hasPrefix("note1") || identifier.hasPrefix("nevent1") || identifier.hasPrefix("naddr1") {
                    showingNoteIdInRow = identifier
                    return .handled
                }
            }
            return .systemAction
        })
        .sheet(isPresented: $showingBroadcastSheet) {
            EventBroadcastSheet(note: note)
        }
        .sheet(item: Binding<IdentifiableString?>(
            get: { showingNoteIdInRow.map { IdentifiableString(id: $0) } },
            set: { showingNoteIdInRow = $0?.id }
        )) { noteId in
            NoteDetailViewWrapper(noteId: noteId.id, onDismiss: { showingNoteIdInRow = nil })
        }
        .alert("No Lightning Address", isPresented: $noLightningAddressAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("This user hasn't configured a lightning address, so they can't receive zaps.")
        }
        .contextMenu {
            if rowData.isOwnNote {
                Button(role: .destructive) {
                    showingDeleteConfirm = true
                } label: {
                    Label("Delete Post", systemImage: "trash")
                }
            }
        }
        .alert("Delete Post", isPresented: $showingDeleteConfirm) {
            Button("Delete", role: .destructive) {
                actions.deleteNote(note.id)
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Request deletion of this post? Not all relays honor NIP-09 deletion requests.")
        }
        .onDisappear { showingUserMenu = false; menuExpanded = false; showingParentUserMenu = false; parentMenuExpanded = false }
    }

    // MARK: - Glass User Menu

    private func toggleUserMenu() {
        if showingUserMenu {
            dismissMenu(expanded: $menuExpanded, showing: $showingUserMenu)
        } else if !rowData.isOwnNote {
            withAnimation(Motion.panel) {
                showingUserMenu = true
                menuExpanded = true
            }
        } else {
            onProfile?(rowData.displayPubkey)
        }
    }

    private func toggleParentUserMenu() {
        if showingParentUserMenu {
            dismissMenu(expanded: $parentMenuExpanded, showing: $showingParentUserMenu)
        } else {
            withAnimation(Motion.panel) {
                showingParentUserMenu = true
                parentMenuExpanded = true
            }
        }
    }

    private func dismissMenu(expanded: Binding<Bool>, showing: Binding<Bool>) {
        withAnimation(Motion.panel) {
            expanded.wrappedValue = false
            showing.wrappedValue = false
        }
    }

    @ViewBuilder
    private var userMenuToolbar: some View {
        let name = rowData.displayProfile?.bestName ?? "user"
        glassToolbar(
            pubkey: rowData.displayPubkey,
            displayName: name,
            isFollowed: rowData.isFollowed,
            expanded: menuExpanded
        ) {
            dismissMenu(expanded: $menuExpanded, showing: $showingUserMenu)
        }
    }

    @ViewBuilder
    private var parentUserMenuToolbar: some View {
        if let parent = rowData.parentNote {
            let name = rowData.parentProfile?.bestName ?? "user"
            glassToolbar(
                pubkey: parent.pubkey,
                displayName: name,
                isFollowed: rowData.isParentFollowed,
                expanded: parentMenuExpanded
            ) {
                dismissMenu(expanded: $parentMenuExpanded, showing: $showingParentUserMenu)
            }
        }
    }

    @ViewBuilder
    private func glassToolbar(pubkey: String, displayName: String, isFollowed: Bool, expanded: Bool, dismiss: @escaping () -> Void) -> some View {
        VStack(spacing: 2) {
            glassIcon(isFollowed ? "person.badge.minus.fill" : "person.badge.plus",
                      tint: isFollowed ? .yellow : .green, expanded: expanded, index: 0) {
                if isFollowed { actions.unfollowUser(pubkey) }
                else { actions.followUser(pubkey) }
                dismiss()
            }
            glassIcon("tortoise.fill", tint: .orange, expanded: expanded, index: 1) {
                actions.throttleUser(pubkey, 3)
                ActionToastManager.shared.show(
                    icon: "tortoise.fill",
                    message: "Slowed down \(displayName)"
                )
                dismiss()
            }
            glassIcon("hand.raised.fill", tint: .red, expanded: expanded, index: 2) {
                actions.blockUser(pubkey)
                ActionToastManager.shared.show(
                    icon: "hand.raised.fill",
                    message: "Blocked \(displayName)",
                    color: .red
                )
                dismiss()
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .modifier(LiquidGlassVerticalModifier())
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
    }

    private func glassIcon(_ icon: String, tint: Color = .white, expanded: Bool, index: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint.opacity(0.85))
                .frame(width: 32, height: 32)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .scaleEffect(expanded ? 1 : 0.01)
        .opacity(expanded ? 1 : 0)
        .animation(
            Motion.staggered(Motion.pop, index: index, step: 0.06),
            value: expanded
        )
    }

    private func actionButton(icon: String, color: Color = .secondary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.appSystem(size: 14, weight: .medium))
                .foregroundColor(color)
            .frame(width: 32, height: 32)
            .background(color.opacity(color == .secondary ? 0.1 : 0.15))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .contentShape(Capsule())
        #if os(macOS)
        .onHover { inside in
            // Handle hover state if needed, though .hoverEffect handles it on iOS
        }
        #endif
    }

    // MARK: - Media Grid Helper

    /// Renders media URLs using FeedMediaView in a swipeable carousel.
    @ViewBuilder
    private func feedMediaCarousel(urls: [URL]) -> some View {
        if urls.isEmpty {
            EmptyView()
        } else if urls.count == 1 {
            // Single media — full width, proper aspect ratio
            FeedMediaView(
                url: urls[0],
                onTap: { onMedia?(urls[0], urls) },
                maxHeight: 400,
                isThumbnail: false
            )
            .frame(maxWidth: .infinity)
        } else {
            // Multiple media — quick snappy fade carousel
            MediaPagerView(items: urls) { url in
                FeedMediaView(
                    url: url,
                    onTap: { onMedia?(url, urls) },
                    maxHeight: 400,
                    isThumbnail: false
                )
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                #if os(iOS)
                .transition(.opacity.animation(Motion.media))
                #endif
            }
            .frame(height: 400)
            // Add a subtle border or background if desired to distinguish bounds
            // But FeedMediaView already has clipShape and overlay
        }
    }

    /// Arms the terminal failure state for the parent-note skeleton: if the
    /// parent still hasn't arrived 12s after a fetch was requested, the
    /// skeleton is replaced with "Could not load original note" and a Retry
    /// action, instead of breathing forever.
    ///
    /// Deliberately does not re-check `rowData.parentNote` before setting the
    /// flag: `rowData` is a `let`, so this escaping closure would only ever
    /// see the value captured 12 seconds ago, never an arrival in between.
    /// Safe because the view always checks `if let parent = rowData.parentNote`
    /// before `else if parentFetchFailed` — a parent that loaded in the
    /// meantime renders regardless of this flag. Do not reorder those branches
    /// without giving this timeout a live way to observe the current note.
    private func scheduleParentFetchTimeout(_ id: String) {
        guard parentFetchStartedAt == nil else { return }
        parentFetchStartedAt = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
            parentFetchFailed = true
        }
    }

    /// Toggle like: delegates to the appropriate action closure. Only the
    /// liking direction pulses — a pulse is confirmation of the tap that just
    /// happened, not a description of the resulting state, so it must not
    /// also fire when a like arrives from backfill or another client.
    private func toggleLike() {
        if rowData.isLiked {
            actions.unlikeNote(note)
        } else {
            actions.likeNote(note)
            Motion.firePulse($likePulse)
        }
    }

    private func shortKey(_ key: String) -> String {
        guard key.count >= 12 else { return key }
        return "npub…" + String(key.suffix(6))
    }

    private func relativeTime(_ date: Date) -> String {
        let diff = Date().timeIntervalSince(date)
        switch diff {
        case ..<60:         return "now"
        case ..<3600:       return "\(Int(diff / 60))m"
        case ..<86400:      return "\(Int(diff / 3600))h"
        case ..<604800:     return "\(Int(diff / 86400))d"
        default:
            let fmt = DateFormatter()
            fmt.dateFormat = "MMM d"
            return fmt.string(from: date)
        }
    }
}

// FeedMediaThumbnail has been replaced by FeedMediaView (see Components/FeedMediaView.swift)

// MARK: - AvatarView

private final class AvatarImageCache {
    static let shared = AvatarImageCache()

    private let cache = NSCache<NSURL, PlatformImage>()
    private var inFlight: [URL: [(PlatformImage?) -> Void]] = [:]
    private let lock = NSLock()

    // Downsample target — large enough for a profile header on @3x retina,
    // small enough that 300 entries fit in ~24 MB.
    private static let targetPixelSize: CGFloat = 256
    private static let estimatedCostPerEntry = 256 * 256 * 4 // bytes

    init() {
        cache.countLimit = 300
        cache.totalCostLimit = 24 * 1024 * 1024
    }

    func image(for url: URL) -> PlatformImage? {
        cache.object(forKey: url as NSURL)
    }

    private func store(_ image: PlatformImage, for url: URL) {
        cache.setObject(image, forKey: url as NSURL, cost: Self.estimatedCostPerEntry)
    }

    /// Loads an avatar, hitting (in order): memory cache → on-disk cache → network.
    /// Coalesces concurrent requests for the same URL and skips known-404s.
    /// `completion` is always called on the main thread.
    func load(url: URL, completion: @escaping (PlatformImage?) -> Void) {
        if let cached = image(for: url) {
            completion(cached)
            return
        }
        if MediaCacheService.shared.isKnown404(url: url) {
            completion(nil)
            return
        }

        lock.lock()
        if inFlight[url] != nil {
            inFlight[url]?.append(completion)
            lock.unlock()
            return
        }
        inFlight[url] = [completion]
        lock.unlock()

        MediaCacheService.shared.downloadQueue.addOperation { [weak self] in
            guard let self = self else { return }

            // Disk cache
            if let data = MediaCacheService.shared.loadFromCache(url: url),
               let img = Self.downsample(data: data) {
                self.finish(url: url, image: img)
                return
            }

            // Network
            URLSession.shared.dataTask(with: url) { data, response, _ in
                guard let data = data,
                      let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      let img = Self.downsample(data: data) else {
                    self.finish(url: url, image: nil)
                    return
                }
                MediaCacheService.shared.saveToCache(url: url, data: data)
                self.finish(url: url, image: img)
            }.resume()
        }
    }

    private func finish(url: URL, image: PlatformImage?) {
        if let image = image {
            store(image, for: url)
        }
        lock.lock()
        let callbacks = inFlight.removeValue(forKey: url) ?? []
        lock.unlock()
        DispatchQueue.main.async {
            callbacks.forEach { $0(image) }
        }
    }

    private static func downsample(data: Data) -> PlatformImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: targetPixelSize
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        #if canImport(AppKit)
        return NSImage(cgImage: cgImage, size: .zero)
        #else
        return UIImage(cgImage: cgImage)
        #endif
    }
}

struct AvatarView: View {
    let url: URL?
    let pubkey: String
    var size: CGFloat = 40
    @State private var image: PlatformImage?

    var body: some View {
        ZStack {
            Circle()
                .fill(avatarGradient)
                .frame(width: size, height: size)

            if let image = image {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                Text(String(pubkey.prefix(1)).uppercased())
                    .font(.appSystem(size: max(8, size * 0.325), weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
            }

            Circle()
                .stroke(Color.platformSeparator, lineWidth: 0.5)
                .frame(width: size, height: size)
        }
        .frame(width: size, height: size)
        .onAppear { loadImage() }
        .onChange(of: url) { _, _ in
            image = nil
            loadImage()
        }
        .onChange(of: pubkey) { _, _ in
            image = nil
            loadImage()
        }
    }

    private var avatarGradient: LinearGradient {
        let first = pubkey.unicodeScalars.first?.value ?? 200
        let hue = Double(first % 360) / 360.0
        let saturation = 0.6 + Double((first / 10) % 30) / 100.0

        return LinearGradient(
            colors: [
                Color(hue: hue, saturation: saturation, brightness: 0.75),
                Color(hue: (hue + 0.15).truncatingRemainder(dividingBy: 1), saturation: saturation, brightness: 0.55)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func loadImage() {
        guard let url = url else { return }

        // Fast synchronous path for the memory cache so already-loaded avatars
        // render without a flash.
        if let cached = AvatarImageCache.shared.image(for: url) {
            if image == nil { image = cached }
            return
        }

        guard image == nil else { return }
        AvatarImageCache.shared.load(url: url) { img in
            if let img = img { image = img }
        }
    }
}

// MARK: - Skeleton Loading Row

struct FeedNoteSkeletonRow: View {
    @State private var shimmer = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Circle()
                    .fill(Color.platformTertiaryGroupedBackground)
                    .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 4) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.platformTertiaryGroupedBackground)
                        .frame(width: 100, height: 12)

                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.platformTertiaryGroupedBackground)
                        .frame(width: 60, height: 10)
                }

                Spacer()
            }

            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.platformTertiaryGroupedBackground)
                    .frame(maxWidth: .infinity)
                    .frame(height: 12)

                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.platformTertiaryGroupedBackground)
                    .frame(maxWidth: .infinity)
                    .frame(height: 12)

                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.platformTertiaryGroupedBackground)
                    .frame(width: 180, height: 12)
            }

            HStack(spacing: 12) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle()
                        .fill(Color.platformTertiaryGroupedBackground)
                        .frame(width: 28, height: 28)
                }
                Spacer()
            }
        }
        .padding(14)
        .background(Color.platformSecondaryGroupedBackground)
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.platformSeparator.opacity(ConfigService.shared.config.useOLED ? 1.5 : 1.0), lineWidth: ConfigService.shared.config.useOLED ? 1.5 : 0.8))
        .opacity(shimmer ? 0.5 : 1.0)
        .animation(Motion.shimmer, value: shimmer)
        // Gated, not just un-animated: flipping `shimmer` with a nil animation
        // would pin the skeleton at 0.5 opacity forever instead of breathing.
        .onAppear { if Motion.shimmer != nil { shimmer = true } }
    }
}

