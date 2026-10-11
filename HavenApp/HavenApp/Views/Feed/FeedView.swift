import SwiftUI

// MARK: - FeedView

struct FeedView: View {
    @StateObject var feedService = FeedService.shared
    @EnvironmentObject var relayManager: RelayProcessManager
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var nostrService: NostrService
    @ObservedObject var pendingManager = PendingPostManager.shared
    @ObservedObject var tutorialCenter = TutorialCenter.shared
    @State var composeContext: ComposeContext?
    /// The diVine, article or recipe composer, when the post button opens one.
    @State var modeComposer: ModeComposer?
    @State var showingFeedMenuEditor = false
    @State var showingDashboard = false
    @AppStorage(FeedMode.menuOrderKey) private var feedMenuOrder = ""
    @AppStorage(FeedMode.menuHiddenKey) private var feedMenuHidden = ""
    var menuModes: [FeedMode] { FeedMode.menuModes(order: feedMenuOrder, hidden: feedMenuHidden) }
    @State var showingNoteId: String?
    @State var showingProfileKey: IdentifiableString?
    @ObservedObject var fillGuide = FillYourVaultCoordinator.shared
    @State var showingMediaUrl: IdentifiableURL?
    @Namespace var mediaZoom
    /// macOS presents the article reader as a sheet; iOS pushes it.
    @State var showingArticle: ArticleRoute?
    @StateObject var recipeService = RecipeFeedService.shared
    @StateObject var marketplaceService = MarketplaceFeedService.shared
    @State var selectedListing: MarketListing?
    @StateObject var liveService = LiveFeedService.shared
    @StateObject var reelsService = ReelsFeedService.shared
    @State var playingStream: LiveStream?
    @State var selectedGridMediaNoteId: String?
    @State var isShowingGridMediaViewer = false
    @State var gridMediaSnapshot: [FeedNote] = []
    @State var galleryDragOffset: CGSize = .zero
    @State var isRefreshing = false
    @State var showingGlobalEveryoneWarning = false
    /// Same warning, raised before Recipes switches to the global set.
    @State var isAtTop: Bool = true
    @State var scrolledNoteID: String?
    @State var threadLineTops = ThreadLineTops()
    /// Rows on screen right now, so switching layouts can keep the post you
    /// were reading in front of you. A plain reference: rows scrolling in and
    /// out must not re-render the feed.
    @State var visibleRows = FeedVisibleRows()
    /// Row to bring back to the top once a layout switch has re-rendered.
    @State var pendingLayoutAnchor: String?
    /// How that scroll moves: with the rows when they reshape, instantly
    /// behind the fade otherwise.
    @State var pendingLayoutAnimation: Animation?
    /// The feed is faded out for an instant while switching to or from
    /// threaded layout.
    @State var layoutFadedOut = false
    @State private var lastScrollOffset: CGFloat = 0
    @State private var isScrollingDown: Bool = false
    @State var navigationPath = NavigationPath()
    /// Non-nil when an iPad split pane owns the note detail column.
    @Environment(\.noteDetailSelection) var noteDetailSelection
    #if os(iOS)
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    #endif
    /// Debounce work item for auto-loading pending notes so overlapping
    /// onChange triggers don't queue duplicate applyPendingNotes() calls.
    @State var autoLoadWork: DispatchWorkItem?
    /// Debounce work item for rebuilding the row data cache to prevent
    /// expensive synchronous operations during active scrolling.
    @State var cacheRebuildWork: DispatchWorkItem?
    /// Cache of pre-resolved row data keyed by note ID. Invalidated when
    /// filteredNotes changes so we avoid re-running resolve() on every
    /// SwiftUI re-render triggered by unrelated state changes.
    @State var rowDataCache: [String: FeedNoteRowData] = [:]

    /// Compact mode state: tracks which note is currently expanded (nil = all collapsed)
    @State var expandedNoteId: String? = nil
    /// Thread cards whose reply fold is open, by thread root id. Held here
    /// rather than in the card because a LazyVStack discards the `@State` of
    /// a card it scrolls off, which would refold a thread behind your back.
    @State var expandedThreadIds: Set<String> = []

    /// Conversations built from `filteredNotes` for threaded mode. Rebuilt on
    /// the same signals as the row-data cache and left empty in the other two
    /// layouts so nothing is grouped that will never be drawn.
    @State var feedThreads: [FeedThread<FeedNote>] = []
    @State var threadRebuildWork: DispatchWorkItem?
    /// A gap-fill regroup is already queued; see regroupIfGapFilled.
    @State var gapRegroupScheduled = false

    // MARK: - Helper Functions

    /// A tapped name or photo in the feed. While the Fill your feed meter is
    /// up it opens the small profile card, so a new account looks before it
    /// follows; otherwise the full profile.
    func openProfile(_ pubkey: String) {
        let guide = FillYourVaultCoordinator.shared
        if FillYourFeedGuide.opensProfileCard(meterShowing: guide.meterShowing) {
            guide.profileCardPubkey = pubkey
        } else {
            showingProfileKey = IdentifiableString(id: pubkey)
        }
    }

    @ViewBuilder
    func feedNoteRowContent(note: FeedNote, profile: FeedProfile?, rowData: FeedNoteRowData, parentIsNext: Bool, isExpanded: Bool) -> some View {
        FeedNoteRow(
            note: note,
            profile: profile,
            rowData: rowData,
            onReply: {
                composeContext = ComposeContext(replyTo: feedService.replyTarget(for: note), quoteTo: nil)
            },
            onQuote: {
                composeContext = ComposeContext(replyTo: nil, quoteTo: feedService.quoteTarget(for: note))
            },
            onProfile: { pubkey in openProfile(pubkey) },
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
        feedStack
            .onAppear { openNotificationNote() }
            .onReceive(NotificationCenter.default.publisher(for: .havenOpenNotificationNote)) { _ in
                openNotificationNote()
            }
        #else
        VStack(spacing: 0) {
            macFeedHeader
            Divider()
            rootContent
        }
        #endif
    }

    /// Width of the media grid itself, which sets how many tiles fit across.
    /// Zero until measured; the grid reads that as the phone count.
    @State var mediaGridWidth: CGFloat = 0

}
