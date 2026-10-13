import SwiftUI
import Combine
import ImageIO
#if os(iOS)
import Photos
#endif

/// The part of a profile that is the same for everyone: banner, name, bio,
/// links, follow counts, the tabs and what is under them, and the readers
/// they open. What you can DO on a profile is not here — your own profile
/// (`MyProfileView`) and anyone else's (`PersonProfileView`) each bring their
/// own badge, action row, toolbar and sheets.
struct ProfileContent<Badge: View, Actions: View, ShopHeader: View>: View {
    let pubkey: String
    @ObservedObject var loader: ProfileFeedLoader
    @ObservedObject var shop: SellerListingsLoader
    @ObservedObject var extras: ProfileExtrasLoader
    /// Set when this profile is a sheet: a close button on the banner, and on
    /// the Mac the app's banners drawn over it.
    var dismissAction: (() -> Void)? = nil
    /// Your own profile keeps its Shop tab, where the Sell button is, even
    /// with nothing listed.
    var shopAlwaysVisible = false
    var shopEmptyText = "Nothing for sale"
    /// Your own Blossom files get the Vault grid's Delete menu.
    var canDeleteMedia = false
    /// Changing it scrolls the page back to the top.
    var scrollToTopToken = 0
    /// Scrolling folds the tab bar. Only the Profile tab's own page: anyone
    /// else's is a sheet or a cover over the bar, and folding the hidden bar
    /// redrew it on every frame of the scroll.
    var foldsTabBar = false
    @ViewBuilder let badge: () -> Badge
    /// Called with 0, 1, 2: each a tighter row, for when the wider one does
    /// not fit on one line.
    @ViewBuilder let actions: (_ compact: Int) -> Actions
    @ViewBuilder let shopHeader: () -> ShopHeader

    /// Not observed: its `profiles` dictionary changes each time any author
    /// arrives, and observing it redrew this page mid-scroll. `metadataWatch`
    /// redraws for this profile's own metadata.
    var nostrService: NostrService { .shared }
    @StateObject private var metadataWatch = ProfileMetadataWatch()
    @EnvironmentObject var configService: ConfigService
    /// Not observed: the main feed changes many times a second while it
    /// loads, and observing all of it redrew this page each time.
    /// `feedWatch` redraws only for the parts this page shows.
    var feedService: FeedService { .shared }
    @StateObject private var feedWatch = ProfileFeedWatch()
    @Environment(\.openURL) var openURL
    /// Built once: a new value each pass invalidated every row under the tabs.
    @State private var feedActions = FeedActions.make(feedService: .shared, nostrService: .shared)

    @State private var showingNoteDetail: FeedNote?
    /// Non-nil when an iPad split pane owns the note detail column.
    @Environment(\.noteDetailSelection) private var noteDetailSelection
    /// True when this profile is a sheet or a pushed page. Sheets inherit the
    /// environment, so without this a profile opened over the split would
    /// select into the detail column hidden behind it.
    @Environment(\.isPresented) private var isPresented
    @State var showingProfileKey: IdentifiableString?
    @State var showingMediaUrl: IdentifiableURL?
    @Namespace private var mediaZoom
    @State var selectedMedia: MediaItem? = nil
    @State var dragOffset: CGSize = .zero
    #if os(iOS)
    @State var saveToPhotosMessage: String? = nil
    #endif
    #if os(macOS)
    @State var keyMonitor: Any? = nil
    #endif
    @State var copiedNpub = false
    @State var copiedLightning = false
    /// Reply or quote from a row.
    @State var composeContext: ComposeContext?

    /// The Following / Followers page, open on the tab that was tapped.
    @State var followListTab: FollowListTab?
    /// The viewer's follower ledger, read before the page opens.
    @State var viewerLedger: FollowerSnapshot?

    /// The late tabs on show. Set only when their loader finishes, so the
    /// tab bar re-spaces once instead of once per tab as each one arrives.
    @State var revealedSections = Set<ProfileSection>()
    /// Set once the profile has waited long enough for its metadata; the
    /// header stops holding space for a bio that is not coming.
    @State var metadataWaitOver = false
    /// Height of the profile's scroll view. A section is at least this tall,
    /// so picking one with a single item keeps the tabs where they were and
    /// leaves blank space below, instead of the page snapping back down.
    @State private var viewportHeight: CGFloat = 0
    /// Width of the scroll view; the banner's height follows it.
    @State var viewportWidth: CGFloat = 0
    /// Height of the bars above the scroll view's content, which the banner
    /// reaches up under.
    @State var topInset: CGFloat = 0
    /// The topmost note on screen, which the scroll view keeps in place.
    @State var scrolledNoteID: String?
    @State var showingArticle: ArticleRoute?
    @State var musicSheet: MusicSheet?
    @State var selectedListing: MarketListing?

    private static var topID: String { "profile-top" }

    var profile: FeedProfile? {
        nostrService.profiles[pubkey]
    }

    var selectedSection: ProfileSection { loader.selectedSection }

    // MARK: - Body

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    bannerHeader
                        .id(Self.topID)
                    VStack(spacing: 0) {
                        // Who, what they say, where to find them, then what you
                        // can do. One rule above the tabs instead of one between
                        // every block.
                        headerBlock
                        if let about = profile?.about, !about.isEmpty {
                            bioBlock(about)
                        } else if awaitingMetadata {
                            bioPlaceholder
                        }
                        if awaitingMetadata {
                            linksPlaceholder
                        } else {
                            linksRow
                        }
                        followCountsRow
                        actionRow
                            .padding(.top, 14)
                        divider
                        sectionTabBar
                        sectionContent
                            .environment(\.feedActions, feedActions)
                            .tabBarBottomPadding()
                            .frame(minHeight: viewportHeight, alignment: .top)
                    }
                    // Top, not centred: the notes' lazy stack can come out
                    // taller when placed than when measured, and centring
                    // split the extra, sliding the header up under the banner.
                    .frame(maxWidth: 720, alignment: .top)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            }
            // Holds the note you are reading in place while notes arrive from
            // each relay and are sorted in above it, and while rows above it
            // grow as their media loads. The main feed does the same.
            .scrollPosition(id: $scrolledNoteID)
            .foldsTabBar(foldsTabBar, feedService: feedService)
            .onGeometryChange(for: CGSize.self) { $0.size } action: {
                viewportHeight = $0.height
                viewportWidth = $0.width
            }
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { topInset = $0 }
            // The banner draws its own scrim under the bar; the system edge would
            // lay a grey band over it.
            .hiddenTopScrollEdge()
            .onChange(of: scrollToTopToken) { _, _ in
                scrolledNoteID = nil
                withAnimation(Motion.fade) { proxy.scrollTo(Self.topID, anchor: .top) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.platformWindowBackground.ignoresSafeArea())
        .onAppear {
            metadataWatch.watch(pubkey)
            loader.start()
            shop.load(pubkey: pubkey)
            extras.load(pubkey: pubkey, relays: loader.extrasRelays)
            revealLateSections()
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { metadataWaitOver = true }
            #if os(macOS)
            installKeyMonitor()
            #endif
        }
        .onChange(of: extras.isLoading) { _, _ in revealLateSections() }
        .onChange(of: shop.isLoading) { _, _ in revealLateSections() }
        .onChange(of: shop.listings.isEmpty) { _, _ in revealLateSections() }
        .onDisappear {
            loader.stop()
            #if os(macOS)
            removeKeyMonitor()
            #endif
        }
        .sheet(item: $showingArticle) { route in
            // In a stack so a comment under the article can open as a note.
            NavigationStack {
                ArticleReaderView(note: route.note)
            }
            .environmentObject(nostrService)
            .environmentObject(configService)
            #if os(macOS)
            .frame(minWidth: 520, minHeight: 480)
            #endif
        }
        .modifier(MusicSheetHost(sheet: $musicSheet))
        .environmentObject(RelayProcessManager.shared)
        .sheet(item: $selectedListing) { listing in
            MarketplaceListingSheet(listing: listing)
                .environmentObject(nostrService)
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
        .sheet(item: $showingProfileKey) { p in
            ProfileView(pubkey: p.id, onDismiss: { showingProfileKey = nil })
                .environmentObject(nostrService)
                .environmentObject(configService)
                #if os(macOS)
                // A macOS sheet with no minimum inherits its content's ideal size and can
                // open too small to use.
                .frame(minWidth: 520, minHeight: 560)
                #endif
        }
        .modifier(FollowListHost(item: $followListTab) { tab in
            followListPage(startOn: tab)
        })
        .mediaViewer(item: $showingMediaUrl, namespace: mediaZoom)
        .hashtagLinks()
        .sheet(item: $composeContext) { ctx in
            ComposeView(onDismiss: { composeContext = nil }, replyTo: ctx.replyTo, quoteTo: ctx.quoteTo, initialContent: ctx.initialContent, restoredDraftId: ctx.draftId)
                .environmentObject(nostrService)
                .environmentObject(configService)
        }
        #if os(macOS)
        // On iPhone and iPad every banner is drawn in its own window above all
        // sheets (BannerWindow in SceneDelegate), so a profile sheet cannot
        // cover one; the Mac still draws them over the sheet itself.
        .overlay(alignment: .top) {
            if dismissAction != nil {
                PillLaneStack()
                    .padding(.top, 4)
                .allowsHitTesting(true)
            }
        }
        .overlay(fullScreenOverlay)
        #else
        .fullScreenCover(isPresented: isPresentingViewer) {
            if let item = selectedMedia {
                mediaViewerContent(for: item)
            }
        }
        #endif
    }

    /// Opens a note in the split pane's detail column when this profile is the
    /// pane's list, and falls back to the sheet everywhere else.
    func openNote(_ note: FeedNote) {
        if let noteDetailSelection, !isPresented {
            noteDetailSelection.select(note)
        } else {
            showingNoteDetail = note
        }
    }
}

private extension View {
    @ViewBuilder
    func foldsTabBar(_ folds: Bool, feedService: FeedService) -> some View {
        if folds {
            self.scrollDirectionTracking(feedService: feedService)
        } else {
            self
        }
    }

    @ViewBuilder
    func hiddenTopScrollEdge() -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            self.scrollEdgeEffectHidden(true, for: .top)
        } else {
            self
        }
    }
}
