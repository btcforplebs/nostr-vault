import SwiftUI
import Combine
import simd
#if canImport(UIKit)
import UIKit
#endif

/// The Trust Path card opened up into a globe. Someone sits at the core (you,
/// at first) with everyone they follow as stars on a sphere around them,
/// people further out as a faint outer shell, and the author between the two.
/// Threads run from the core through each person who follows the author.
/// Each star's spot comes from its key (`TrustMap.direction`), so nothing is
/// ever laid out: spinning and zooming only move the camera, and re-centering
/// on someone only changes how far each star sits from the core.
struct TrustWebView: View {
    let author: String
    let path: TrustPath
    /// The WOT tab's globe: it follows your follow list as it loads or
    /// changes, and tapping the tab again brings it back to you.
    var isWOTTab = false
    @EnvironmentObject var nostrService: NostrService
    @Environment(\.floatingTabBarHeight) var tabBarHeight

    /// One globe: who is at the core and what we know about their follows.
    struct Frame {
        let center: String
        /// Everyone `center` follows: the stars on the inner sphere.
        let ring: [String]
        /// False when no relay had `center`'s follow list, so the empty sphere
        /// means "unknown", not "follows no one".
        let listFound: Bool
        let path: TrustPath
        /// Every bridge found so far, sorted: everyone when the saved web
        /// knew them, else the card's 5 until "Show everyone".
        var bridges: [String]
        /// Signers whose lists already came back, so a batch skips them.
        var seen: Set<String>
        /// Relays answered with nothing new: the count is the whole count.
        var exhausted: Bool
        /// 3-hop routes once "look deeper" ran; nil before.
        var chains: [TrustMap.Chain]?

        init(center: String, ring: [String], listFound: Bool = true, path: TrustPath) {
            self.center = center
            self.ring = ring
            self.listFound = listFound
            self.path = path
            bridges = path.lit
            seen = Set(bridges)
            // The card asks for one more list than it shows: no extra means
            // it already has everyone.
            exhausted = path.complete || !path.hasMore
        }
    }

    @State var crumbs: [String] = []
    @State var frames: [String: Frame] = [:]
    @State var myFollows: Set<String> = []
    /// The faint outer shell around you: your web of trust past your follows.
    @State var haze: [String] = []
    @State var profilePubkey: String?
    /// Per person whose own globe is showing: the follows worth a profile
    /// fetch, so their faces can be pictures (`TrustMap.faceCandidates`).
    @State var faceCandidates: [String: [String]] = [:]
    /// How much you and each person interact (`TrustMap.engagementScores`):
    /// your own globe opens on the busiest faces.
    @State var engagement: [String: Int] = [:]
    /// People whose current picture has loaded, so a face is never initials
    /// or a broken image. Keyed by pubkey and picture URL.
    @State var renderedPictures: Set<String> = []
    @State var pictureLoader: Task<Void, Never>?
    /// The WOT tab's Close and Further out faces: the people past your
    /// follows worth a profile fetch (`TrustMap.layerFaceCandidates`).
    @State var layerCandidates: [TrustMap.Layer: [String]] = [:]
    @State var layerPictureLoader: Task<Void, Never>?
    /// Your wider web, for the search's "In your web" tag.
    @State var web: Set<String> = []
    /// How many of your follows follow each person past them (the relay's
    /// vouches), and who of the drawn shell is Close. nil on an old cache.
    @State var vouches: [String: Int]?
    @State var closeHaze: Set<String> = []
    @State var query = ""
    @FocusState var searchFocused: Bool
    @State var searchingRelays = false
    @State var relaySearch: Task<Void, Never>?
    /// The WOT tab's layer picker: which part of your web is lit.
    @State var layer: TrustMap.Layer = .everyone
    /// The WOT tab's filter icons that are on, and who they leave lit (nil:
    /// none on, nothing dims). Reset when you leave the tab.
    @State var filters: Set<TrustMap.Filter> = []
    @State var filterLit: Set<String>?
    /// Matching people worth a picture, most interacted with first.
    @State var filterCandidates: [String] = []
    @State var filterPictureLoader: Task<Void, Never>?
    /// Your follows who follow you, from the relay's follower ledger.
    @State var followsBack: Set<String> = []
    /// The ledger was read (nil before, or false when the relay had none).
    @State var followsBackLoaded: Bool?
    /// The line under the bar after a filter tap: its name and count.
    @StateObject var filterNote = FilterNoteModel()
    /// The WOT tab's search field is open under the bar.
    @State var searchOpen = false
    /// A relay rebuild seen running from the WOT tab, and the people it has
    /// found so far who weren't on the old map, lit as stars while it runs.
    @State var liveRebuild = false
    @State var arrivals: Set<String> = []
    /// The WOT tab's trust card: who was tapped or searched, and how they
    /// reach you (nil while it's being traced).
    @State var card: String?
    @State var cardPath: TrustPath?
    @State var messagePubkey: String?
    /// The refresh button's run: which step, 0 to 3, and nil when idle.
    @State var refreshStep: Int?
    /// The bar's fill, 0 to 3 (one per step), and what it is doing now.
    @State var refreshValue = 0.0
    @State var refreshCaption = ""
    /// The last rebuild didn't save a new web (relay off, offline, stopped):
    /// the bar ends on why instead of "Up to date".
    @State var refreshFailed = false
    /// Long enough on screen that an empty web means no graph, not a slow one.
    @State var webWaitedOut = false
    /// Your follow list is still on its way (FeedService, mirrored so this
    /// view doesn't redraw on every feed change).
    @State var contactsLoading = true

    /// Width of the globe's own pane. The trust card becomes a side panel once
    /// there is room for one beside the globe instead of across its bottom.
    @State private var paneWidth: CGFloat = 0

    /// Wide enough for a 360pt panel and a globe that is still the subject.
    var cardIsSidePanel: Bool {
        isWOTTab && AdaptiveLayout.usesWidth && paneWidth >= 900
    }

    var me: String { ConfigService.shared.activeAccountHexPubkey }
    var centerKey: String { crumbs.last ?? me }
    var frame: Frame? { frames[centerKey] }

    var body: some View {
        GeometryReader { geo in
            if isWOTTab {
                // Full bleed, like the feed: space runs under the status bar
                // and the floating tab bar, and the bar's glass sits over it.
                // On every width: the trust card does the explaining.
                globeArea.overlay { globeTutorialAnchor }.overlay(alignment: .top) {
                    wotTopRows(height: geo.size.height)
                        .frame(maxWidth: 560)
                        // The side-panel card owns the trailing edge; the rows
                        // centre in what is left rather than running under it.
                        .padding(.trailing, cardIsSidePanel ? AdaptiveLayout.sidePanelWidth : 0)
                }
            } else {
                // A post's globe: the WOT tab's card does the explaining, so it
                // reads and moves like the tab.
                VStack(spacing: 0) {
                    topRows.padding(.top, 8)
                    globeArea
                }
            }
        }
        .measureWidth { paneWidth = $0 }
        .background(GlobeSpace())
        // Space is dark whatever the app's appearance; sheets opened from here
        // keep the app's own.
        .environment(\.colorScheme, .dark)
        #if os(iOS)
        // The WOT tab's bar is the feed's: two glass pills, no title.
        .navigationTitle(isWOTTab ? "" : centerKey == me ? "Web of Trust" : name(centerKey))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(GlobeSpace.edge, for: .navigationBar)
        .toolbarBackground(isWOTTab ? .hidden : .visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        #else
        .navigationTitle(centerKey == me ? "Web of Trust" : name(centerKey))
        #endif
        .toolbar { toolbarItems }
        .onAppear {
            guard frames[me] == nil else { return }
            crumbs = [me]
            let follows = FeedService.shared.followedPubkeys
            myFollows = Set(follows)
            frames[me] = Frame(center: me, ring: follows, path: path)
            if !isWOTTab, author != me { openCard(author) }
            nostrService.fetchMissingProfiles(
                for: [me, author] + TrustMap.spread(frames[me]?.bridges ?? [], count: TrustGlobeCanvas.maxFaces))
            prepareFaces(me)
            recomputeHaze()
            Task { await loadEngagement() }
        }
        .task {
            try? await Task.sleep(for: .seconds(15))
            webWaitedOut = true
        }
        .task(id: isWOTTab) {
            guard isWOTTab else { return }
            await followRebuilds()
        }
        .onReceive(FeedService.shared.$wotPubkeys.dropFirst().removeDuplicates()) { _ in
            // On a cold start the graph lands after the globe opened. Only on
            // a change: with an empty graph, recomputeHaze() reloads the cache
            // and assigns the same empty set, which would land here again.
            recomputeHaze()
        }
        .onReceive(FeedService.shared.$isLoadingContacts.combineLatest(FeedService.shared.$hasAttemptedContactLoad)) {
            contactsLoading = $0 || !$1
        }
        .onChange(of: query) { _, text in searchRelays(text) }
        .onChange(of: layer) { _, _ in prepareLayerFaces() }
        .onReceive(FeedService.shared.$followedPubkeys.dropFirst()) { follows in
            // In place, so you stay wherever you'd gone on the globe.
            guard isWOTTab, Set(follows) != myFollows else { return }
            myFollows = Set(follows)
            // Keep what the globe had already found around you.
            var updated = Frame(center: me, ring: follows, path: path)
            if let old = frames[me] {
                updated.bridges = old.bridges
                updated.seen = old.seen
                updated.exhausted = old.exhausted
                updated.chains = old.chains
            }
            frames[me] = updated
            prepareFaces(me)
            // Someone you unfollowed moves out to the haze; a new follow leaves it.
            recomputeHaze()
        }
        .onReceive(NotificationCenter.default.publisher(for: .wotTabReselected)) { _ in
            guard isWOTTab else { return }
            clearSearch()
            searchOpen = false
            closeCard()
            jump(to: 0)
        }
        // The WOT tour points into the globe; a sheet over it hides what the card points at.
        .onChange(of: wotSheetOpen) { _, open in
            if isWOTTab { TutorialCenter.shared.setCovered("wot", open) }
        }
        .onDisappear {
            guard isWOTTab else { return }
            TutorialCenter.shared.setCovered("wot", false)
            filters = []
            applyFilters()
        }
        .onChange(of: web) { _, _ in if !filters.isEmpty { applyFilters() } }
        .onChange(of: engagement) { _, _ in if !filters.isEmpty { applyFilters() } }
        .sheet(item: Binding<IdentifiableString?>(
            get: { messagePubkey.map { IdentifiableString(id: $0) } },
            set: { messagePubkey = $0?.id }
        )) { p in
            #if os(iOS)
            MessageComposerView(recipientPubkey: p.id)
            #else
            DMThreadView(counterpartyPubkey: p.id)
            #endif
        }
        .sheet(item: Binding<IdentifiableString?>(
            get: { profilePubkey.map { IdentifiableString(id: $0) } },
            set: { profilePubkey = $0?.id }
        )) { p in
            ProfileView(pubkey: p.id, onDismiss: { profilePubkey = nil })
        }
    }
}
