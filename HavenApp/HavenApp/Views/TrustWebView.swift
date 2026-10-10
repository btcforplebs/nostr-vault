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
    @Environment(\.floatingTabBarHeight) private var tabBarHeight

    /// One globe: who is at the core and what we know about their follows.
    struct Frame {
        let center: String
        /// Everyone `center` follows: the stars on the inner sphere.
        let ring: [String]
        /// False when no relay had `center`'s follow list, so the empty sphere
        /// means "unknown", not "follows no one".
        let listFound: Bool
        let path: TrustPath
        /// Every bridge found so far, sorted; starts as the card's 5.
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
            bridges = path.bridges
            seen = Set(path.bridges)
            // The card asks for one more list than it shows: no extra means
            // it already has everyone.
            exhausted = !path.hasMore
        }
    }

    @State private var crumbs: [String] = []
    @State private var frames: [String: Frame] = [:]
    @State private var peek: String?
    @State private var myFollows: Set<String> = []
    /// The faint outer shell around you: your web of trust past your follows.
    @State private var haze: [String] = []
    /// Per person, so re-centering mid-load neither blocks nor mislabels the
    /// next person's globe.
    @State private var loadingMore: Set<String> = []
    @State private var lookingDeeper: Set<String> = []
    /// No relay answered: offer a retry instead of a final answer.
    @State private var failed: Set<String> = []
    @State private var deeperFailed: Set<String> = []
    @State private var profilePubkey: String?
    @State private var showingList = false
    /// Per person whose own globe is showing: the follows worth a profile
    /// fetch, so their faces can be pictures (`TrustMap.faceCandidates`).
    @State private var faceCandidates: [String: [String]] = [:]
    /// How much you and each person interact (`TrustMap.engagementScores`):
    /// your own globe opens on the busiest faces.
    @State private var engagement: [String: Int] = [:]
    /// People whose current picture has loaded, so a face is never initials
    /// or a broken image. Keyed by pubkey and picture URL.
    @State private var renderedPictures: Set<String> = []
    @State private var pictureLoader: Task<Void, Never>?
    /// Your wider web, for the search's "In your web" tag.
    @State private var web: Set<String> = []
    /// How many of your follows follow each person past them (the relay's
    /// vouches), and who of the drawn shell is Close. nil on an old cache.
    @State private var vouches: [String: Int]?
    @State private var closeHaze: Set<String> = []
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @State private var searchingRelays = false
    @State private var relaySearch: Task<Void, Never>?
    /// The WOT tab's layer picker: which part of your web is lit.
    @State private var layer: TrustMap.Layer = .everyone
    /// The WOT tab's search field is open under the bar.
    @State private var searchOpen = false
    /// People who joined your web since you last looked, for the
    /// "↑ N new people" pill; `webSeen` is the count they're measured from.
    @State private var newPeople = 0
    @State private var webSeen: Int?
    @State private var newPeopleFade: Task<Void, Never>?
    /// A relay rebuild seen running from the WOT tab: the people it has found
    /// so far who weren't on the old map, lit as stars while it runs, and how
    /// many of its newcomers the pill was tapped away at.
    @State private var liveRebuild = false
    @State private var arrivals: Set<String> = []
    @State private var arrivalsDismissed = 0
    /// Set from a rebuild's first report until its pill folds away.
    @State private var liveCounted = false
    /// The WOT tab's trust card: who was tapped or searched, and how they
    /// reach you (nil while it's being traced).
    @State private var card: String?
    @State private var cardPath: TrustPath?
    @State private var messagePubkey: String?
    /// The refresh button's run: which step, 0 to 3, and nil when idle.
    @State private var refreshStep: Int?
    /// The bar's fill, 0 to 3 (one per step), and what it is doing now.
    @State private var refreshValue = 0.0
    @State private var refreshCaption = ""
    /// The last rebuild didn't save a new web (relay off, offline, stopped):
    /// the bar ends on why instead of "Up to date".
    @State private var refreshFailed = false
    /// Long enough on screen that an empty web means no graph, not a slow one.
    @State private var webWaitedOut = false
    /// Your follow list is still on its way (FeedService, mirrored so this
    /// view doesn't redraw on every feed change).
    @State private var contactsLoading = true

    private var me: String { ConfigService.shared.activeAccountHexPubkey }
    private var centerKey: String { crumbs.last ?? me }
    private var frame: Frame? { frames[centerKey] }

    /// Past this width (iPad, Mac) the globe takes the screen and the words
    /// move to a side panel.
    private static let wideWidth: CGFloat = 760

    var body: some View {
        GeometryReader { geo in
            if geo.size.width >= Self.wideWidth, !isWOTTab {
                HStack(spacing: 0) {
                    globeArea.overlay(alignment: .topLeading) {
                        topRows.frame(maxWidth: 460, alignment: .leading).padding(.top, 12)
                    }
                    sidePanel.frame(width: 360)
                }
            } else if isWOTTab {
                // Full bleed, like the feed: space runs under the status bar
                // and the floating tab bar, and the bar's glass sits over it.
                // On every width: the explainer side panel went with the footer.
                globeArea.overlay { globeTutorialAnchor }.overlay(alignment: .top) {
                    wotTopRows(height: geo.size.height).frame(maxWidth: 560)
                }
            } else {
                VStack(spacing: 0) {
                    topRows.padding(.top, 8)
                    globeArea
                    footer
                }
            }
        }
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
        .onChange(of: web.count) { _, count in countNewPeople(count) }
        .onAppear {
            guard frames[me] == nil else { return }
            crumbs = [me]
            let follows = FeedService.shared.followedPubkeys
            myFollows = Set(follows)
            frames[me] = Frame(center: me, ring: follows, path: path)
            nostrService.fetchMissingProfiles(for: [me, author] + path.bridges)
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
            peek = nil
            clearSearch()
            searchOpen = false
            closeCard()
            jump(to: 0)
        }
        .sheet(isPresented: $showingList) { peopleList }
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

    // MARK: - Globe

    /// Clipped to its box everywhere but the WOT tab, where it runs to the
    /// screen's edges.
    /// The WoT tutorial's first card points at the middle of the globe, you
    /// and the faces nearest you. The whole globe is nearly the screen's
    /// height, which leaves the card no room above or below it.
    private var globeTutorialAnchor: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height) * 0.5
            Color.clear
                .frame(width: side, height: side)
                .tutorialAnchor(TutorialContent.wotGlobe)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var globeArea: some View {
        if isWOTTab { globeLayers } else { globeLayers.clipped() }
    }

    private var globeLayers: some View {
        ZStack(alignment: .bottomLeading) {
            TrustGlobeCanvas(frame: frame, center: centerKey, me: me, author: author,
                             myFollows: myFollows, haze: haze, closeHaze: closeHaze, ringFaces: ringFaces,
                             running: profilePubkey == nil && !showingList,
                             layer: isWOTTab ? layer : .everyone,
                             summary: summary,
                             avatar: avatar, name: name, onTap: tapped,
                             focus: isWOTTab ? card : nil,
                             onEmptyTap: { peek = nil; closeCard(); searchFocused = false })
                .ignoresSafeArea(edges: isWOTTab ? .all : [])
            if frame == nil {
                statusPill("Loading \(name(centerKey))'s follows…", face: centerKey)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if loadingMyFollows {
                statusPill("Loading your follows…", face: me)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if mappingWeb, peek == nil, !isWOTTab {
                statusPill("Mapping your wider web…")
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.bottom, 14)
            }
            if let peek { peekCard(peek) }
            if isWOTTab, let card { trustCard(card).transition(.move(edge: .bottom).combined(with: .opacity)) }
            if !isWOTTab, !query.trimmingCharacters(in: .whitespaces).isEmpty {
                GeometryReader { geo in
                    // With the keyboard up the floating tab bar rides on it,
                    // over the bottom of the globe.
                    searchResults(maxHeight: max(120, min(380, geo.size.height - (searchFocused ? tabBarHeight : 0) - 20)))
                }
            }
        }
        .overlay(alignment: .top) { if !isWOTTab { refreshBar } }
    }

    /// Your own globe, before your follow list has come in.
    private var loadingMyFollows: Bool {
        guard centerKey == me, let frame, frame.ring.isEmpty else { return false }
        return contactsLoading || refreshStep == 1
    }

    /// Your follows are in but the wider web around them isn't yet.
    private var mappingWeb: Bool {
        guard isWOTTab, centerKey == me, haze.isEmpty, let frame, !frame.ring.isEmpty else { return false }
        return !webWaitedOut || refreshStep == 2
    }

    /// A loading state you can't miss: a spinner, what is loading, and whose.
    private func statusPill(_ text: String, face: String? = nil) -> some View {
        HStack(spacing: 10) {
            if let face {
                AvatarView(url: nostrService.profiles[face]?.pictureURL, pubkey: face, size: 28)
            }
            ProgressView().controlSize(.small).tint(.white)
            Text(text)
                .font(.appSystem(size: 14, weight: .semibold))
                .lineLimit(1)
        }
        .padding(.leading, face == nil ? 14 : 6)
        .padding(.trailing, 16)
        .padding(.vertical, 8)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 14, y: 4)
        .accessibilityElement(children: .combine)
        .allowsHitTesting(false)
    }

    // MARK: - WOT tab bar

    @ToolbarContentBuilder private var toolbarItems: some ToolbarContent {
        #if os(iOS)
        if isWOTTab {
            ToolbarItem(placement: .navigationBarLeading) {
                ChromeMorphCapsule(alignment: .leading, isEnabled: false) {
                    layerMenu.tutorialAnchor(TutorialContent.wotLayers)
                }
            }
            .hidingSharedToolbarBackground()
            ToolbarItem(placement: .navigationBarTrailing) {
                ChromeMorphCapsule(alignment: .trailing, isEnabled: false) {
                    HStack(spacing: 4) {
                        IconFilterButton(icon: "magnifyingglass", tooltip: "Find someone",
                                         isSelected: searchOpen, color: .havenPurple) { toggleSearch() }
                            .tutorialAnchor(TutorialContent.wotSearch)
                        Divider().frame(height: 20).padding(.horizontal, 4)
                        IconFilterButton(icon: "globe", tooltip: "Globe",
                                         isSelected: !showingList, color: .havenPurple) { showingList = false }
                        IconFilterButton(icon: "list.bullet", tooltip: "List",
                                         isSelected: showingList, color: .havenPurple) { showingList = true }
                    }
                    .padding(.horizontal, 3)
                    .padding(.vertical, 4)
                }
            }
            .hidingSharedToolbarBackground()
        } else {
            listToolbarItem
        }
        #else
        if isWOTTab {
            ToolbarItem(placement: .primaryAction) {
                Button { refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(refreshStep != nil)
                    .accessibilityLabel(Text("Update your Web of Trust"))
            }
        }
        listToolbarItem
        #endif
    }

    private var listToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button { showingList = true } label: { Image(systemName: "list.bullet") }
                .accessibilityLabel(Text("People on this globe"))
        }
    }

    private var layerCounts: [TrustMap.Layer: Int] {
        TrustMap.layerCounts(me: me, follows: myFollows, web: web, vouches: vouches)
    }

    /// The feed picker's shape: the layer's icon, its name and a chevron, with
    /// the rare Rebuild at the bottom after a divider.
    private var layerMenu: some View {
        let counts = layerCounts
        return Menu {
            Picker(selection: $layer) {
                ForEach(TrustMap.layers(hasVouches: vouches != nil), id: \.self) { item in
                    // Compact counts (15K) keep each row on one line; a menu
                    // row drops a second Text, so there's no subtitle.
                    let count = (counts[item] ?? 0).formatted(.number.notation(.compactName))
                    Label("\(item.title) · \(count)", systemImage: item.symbolName)
                        .tag(item)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)

            Divider()

            Button { refresh() } label: {
                Label(refreshStep == nil ? "Rebuild your web" : "Rebuilding…", systemImage: "arrow.clockwise")
            }
            .disabled(refreshStep != nil)
        } label: {
            HStack(spacing: 0) {
                Image(systemName: layer.symbolName)
                    .font(.appSystem(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 30, height: 30)
                HStack(spacing: 3) {
                    Text(layer.title)
                        .font(.appSystem(size: 17, weight: .bold))
                    Image(systemName: "chevron.down")
                        .font(.appSystem(size: 9, weight: .bold))
                }
                .foregroundColor(.white)
                .padding(.leading, 8)
                .padding(.trailing, 12)
            }
            .padding(.leading, 7)
            .padding(.vertical, 7)
            .fixedSize()
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel("Showing: \(layer.title)")
        .accessibilityValue("\((counts[layer] ?? 0).formatted()) people")
        .accessibilityHint("Pick which part of your web to light up, or rebuild it")
    }

    private func toggleSearch() {
        if searchOpen {
            clearSearch()
            withAnimation(Motion.fade) { searchOpen = false }
        } else {
            peek = nil
            closeCard()
            withAnimation(Motion.fade) { searchOpen = true }
            searchFocused = true
        }
    }

    /// Under the bar: the search when it's open, the way back once you've
    /// moved off yourself, and the live pill.
    private func wotTopRows(height: CGFloat) -> some View {
        VStack(alignment: .center, spacing: 8) {
            if searchOpen {
                searchField.padding(.horizontal)
                if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    searchResults(maxHeight: max(120, min(380, height - 90 - (searchFocused ? tabBarHeight : 0))))
                        .padding(.top, -6)
                }
            }
            if crumbs.count > 1 { crumbRow }
            livePill
        }
        .padding(.top, 8)
        .transition(.opacity)
    }

    /// The feed's purple "New Posts" button, for people: a rebuild running,
    /// or how many joined your web since you looked. Nothing when neither.
    @ViewBuilder private var livePill: some View {
        let rebuilding = refreshStep != nil || mappingWeb || liveRebuild
        if rebuilding || newPeople > 0 {
            Button {
                if liveRebuild { arrivalsDismissed += newPeople }
                withAnimation(Motion.fade) { newPeople = 0 }
            } label: {
                HStack(spacing: 8) {
                    if refreshStep != nil, refreshValue >= 3 {
                        // How the Rebuild button's run ended, over any count.
                        Image(systemName: refreshFailed ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                            .font(.appSystem(size: 13, weight: .bold))
                        Text(refreshCaption)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                    } else if newPeople > 0 {
                        Image(systemName: "arrow.up").font(.appSystem(size: 12, weight: .bold))
                        Text("\(newPeople.formatted()) new people")
                            .monospacedDigit()
                            .contentTransition(.numericText(value: Double(newPeople)))
                    } else if refreshStep != nil {
                        // The Rebuild button's steps.
                        ProgressView().controlSize(.mini).tint(.white)
                        Text(refreshCaption)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                    } else {
                        ProgressView().controlSize(.mini).tint(.white)
                        Text("Mapping your web")
                    }
                }
                .font(.appSystem(size: 13, weight: .bold))
                .padding(.vertical, 10)
                .padding(.horizontal, 20)
                .frame(maxWidth: 340)
                .background(
                    Capsule()
                        .fill(Color.havenPurple)
                        .shadow(color: Color.black.opacity(0.4), radius: 8, x: 0, y: 4)
                )
                .foregroundColor(.white)
            }
            .buttonStyle(.plain)
            .disabled(newPeople == 0)
            .accessibilityLabel(refreshStep != nil && (refreshValue >= 3 || newPeople == 0) ? refreshCaption
                                : newPeople > 0 ? "\(newPeople) new people in your web" : "Your web is updating")
            .animation(Motion.fade, value: newPeople)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    /// The web grew: count the newcomers into the pill, which folds away a
    /// few seconds after the last one arrives. The first count is the start.
    private func countNewPeople(_ count: Int) {
        guard isWOTTab else { return }
        // A rebuild the relay reports on counts its own newcomers, live; the
        // saved web landing afterwards is the same people again.
        guard !liveCounted else { webSeen = count; return }
        guard let seen = webSeen else { webSeen = count; return }
        guard count > seen else { webSeen = count; return }
        withAnimation(Motion.fade) { newPeople += count - seen }
        webSeen = count
        newPeopleFade?.cancel()
        newPeopleFade = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            withAnimation(Motion.fade) { newPeople = 0 }
        }
    }

    /// Follows the relay's rebuilds while the WOT tab is open, whoever started
    /// them (the daily timer, the boot check or the dropdown): newcomers fade
    /// in as stars and count up in the pill, and the saved web loads when the
    /// rebuild ends.
    private func followRebuilds() async {
        var cursor = 0
        while !Task.isCancelled {
            let progress = await Task.detached { WotRefresh.progress() }.value
            if let progress, progress.running {
                if !liveRebuild {
                    liveRebuild = true
                    liveCounted = true
                    newPeopleFade?.cancel()
                    cursor = 0
                    arrivals = []
                    arrivalsDismissed = 0
                }
                let from = cursor
                if let batch = await Task.detached(operation: { WotRefresh.newcomers(from: from) }).value {
                    cursor = batch.total
                    if !batch.pubkeys.isEmpty {
                        arrivals.formUnion(batch.pubkeys)
                        recomputeHaze()
                    }
                }
                let count = max(0, (progress.new ?? arrivals.count) - arrivalsDismissed)
                if count != newPeople { withAnimation(Motion.fade) { newPeople = count } }
            } else if liveRebuild {
                liveRebuild = false
                cursor = 0
                // Saved: the new map has everyone that lit up. Stopped: the
                // old one stays, and the stars that came in fade back out.
                arrivals = []
                FeedService.shared.loadWotPubkeys()
                recomputeHaze()
                newPeopleFade = Task {
                    try? await Task.sleep(for: .seconds(5))
                    guard !Task.isCancelled else { return }
                    withAnimation(Motion.fade) { newPeople = 0 }
                    liveCounted = false
                }
            }
            try? await Task.sleep(for: .seconds(liveRebuild ? 1 : 5))
        }
    }

    // MARK: - Refresh

    @ViewBuilder private var refreshBar: some View {
        if refreshStep != nil {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: min(refreshValue, 3), total: 3)
                    .tint(.havenPurple)
                    .animation(.easeOut(duration: 0.3), value: refreshValue)
                Text(refreshCaption)
                    .font(.appSystem(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal)
            .padding(.top, 4)
            .transition(.opacity)
            .accessibilityElement(children: .combine)
        }
    }

    /// The refresh button: your follow list again, a rebuild of your web
    /// by the relay (the same one it runs daily), then the faces' pictures.
    private func refresh() {
        guard refreshStep == nil else { return }
        withAnimation {
            refreshStep = 0
            refreshValue = 0.05
            refreshCaption = "Updating your follows…"
            refreshFailed = false
        }
        Task {
            await FeedService.shared.refreshContactList()
            refreshStep = 1
            refreshValue = 1
            refreshCaption = "Rebuilding your web…"
            let saved = await rebuildWeb()
            let outcome = refreshCaption
            FeedService.shared.loadWotPubkeys()
            recomputeHaze()
            refreshStep = 2
            refreshValue = 2
            refreshCaption = "Loading profile pictures…"
            await loadEngagement(force: true)
            try? await Task.sleep(for: .milliseconds(900))
            refreshValue = 3
            refreshFailed = !saved
            refreshCaption = saved ? "Up to date" : outcome
            try? await Task.sleep(for: .milliseconds(saved ? 700 : 3500))
            withAnimation { refreshStep = nil }
        }
    }

    /// Asks the relay to rebuild the graph now and follows its progress until
    /// it is saved. A relay that isn't running leaves the graph as it is.
    /// - Returns: whether the relay saved a new web.
    private func rebuildWeb() async -> Bool {
        let started = await Task.detached { RefreshWotC() == 1 }.value
        guard started else {
            refreshCaption = "Relay isn't running. Showing your last saved web."
            try? await Task.sleep(for: .seconds(1.5))
            return false
        }
        // The relay gives up on a slow fetch itself; this only stops a
        // hung poll from holding the bar forever.
        let start = Date()
        var phase = "", phaseStart = start
        for _ in 0..<720 {
            try? await Task.sleep(for: .milliseconds(500))
            let progress = await Task.detached { WotRefresh.progress() }.value
            guard let progress else { continue }
            // A new phase or a finished batch restarts the creep.
            let step = "\(progress.phase)-\(progress.batchesDone)"
            if step != phase { phase = step; phaseStart = Date() }
            refreshValue = 1 + progress.fraction(phaseSeconds: Date().timeIntervalSince(phaseStart))
            refreshCaption = progress.running
                ? "\(progress.caption) · \(Int(Date().timeIntervalSince(start)))s"
                : progress.caption
            if !progress.running { return progress.phase == "saved" }
        }
        refreshCaption = "The rebuild is taking too long. Showing your last saved web."
        return false
    }

    // MARK: - Search

    @ViewBuilder private var topRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isWOTTab { searchField.padding(.horizontal) }
            // On the WOT tab a lone "You" chip says nothing the globe doesn't.
            if !isWOTTab || crumbs.count > 1 { crumbRow }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundColor(.secondary)
            TextField("Find someone", text: $query)
                .focused($searchFocused)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .submitLabel(.search)
                .onSubmit { if let first = searchMatches.first { pick(first) } }
            if !query.isEmpty {
                Button { clearSearch() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear search"))
            }
        }
        .font(.appSystem(size: 15))
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.08)))
    }

    /// Who the search finds: a pasted key, or names you've seen, people you
    /// follow first.
    private var searchMatches: [String] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count == 64, text.allSatisfy(\.isHexDigit) { return [text.lowercased()] }
        let bare = text.hasPrefix("nostr:") ? String(text.dropFirst(6)) : text
        if bare.lowercased().hasPrefix("npub1"), let hex = NpubValidation.hexPubkey(fromNpub: bare) { return [hex] }
        let people = nostrService.profiles.values.map {
            TrustMap.Person(pubkey: $0.pubkey, names: [$0.displayName, $0.name, $0.nip05].compactMap { $0 })
        }
        return TrustMap.searchPeople(text, in: people, follows: myFollows, web: web)
    }

    private func searchResults(maxHeight: CGFloat) -> some View {
        let matches = searchMatches
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(matches, id: \.self) { pubkey in
                    Button { pick(pubkey) } label: { searchRow(pubkey) }
                        .buttonStyle(.plain)
                        .accessibilityHint(Text("Shows how they reach you"))
                }
                if searchingRelays {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Searching relays…").foregroundColor(.secondary)
                    }
                    .font(.appSystem(size: 14))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                } else if matches.isEmpty {
                    Text("No one called \u{201C}\(query.trimmingCharacters(in: .whitespaces))\u{201D} yet.")
                        .font(.appSystem(size: 14))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: maxHeight)
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 18, y: 6)
        .padding(.horizontal)
        .padding(.top, 6)
    }

    private func searchRow(_ pubkey: String) -> some View {
        let tag = pubkey == me ? "You" : myFollows.contains(pubkey) ? "You follow"
            : web.contains(pubkey) ? "In your web" : nil
        return HStack(spacing: 12) {
            AvatarView(url: nostrService.profiles[pubkey]?.pictureURL, pubkey: pubkey, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(name(pubkey)).font(.appSystem(size: 15, weight: .semibold)).foregroundColor(.primary).lineLimit(1)
                if let nip05 = nostrService.profiles[pubkey]?.nip05, !nip05.isEmpty {
                    Text(nip05).font(.appSystem(size: 12)).foregroundColor(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if let tag {
                Text(tag)
                    .font(.appSystem(size: 11, weight: .semibold))
                    .foregroundColor(tag == "In your web" ? .secondary : .havenPurple)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    /// Names you haven't seen yet: ask the search relays, after a pause in
    /// typing. Profiles they return join the cache, so the list re-ranks.
    private func searchRelays(_ text: String) {
        relaySearch?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, !trimmed.lowercased().hasPrefix("npub1") else {
            searchingRelays = false
            return
        }
        searchingRelays = true
        relaySearch = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            nostrService.globalSearch(query: trimmed) { results in
                if results.isFinished, query.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed {
                    searchingRelays = false
                }
            }
            // A relay that never answers mustn't leave the spinner on.
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            searchingRelays = false
        }
    }

    private func pick(_ pubkey: String) {
        clearSearch()
        if isWOTTab {
            withAnimation(Motion.fade) { searchOpen = false }
            return pubkey == me ? closeCard() : openCard(pubkey)
        }
        peek = nil
        if crumbs.count > 1 { crumbs = [me] }
        if pubkey != me { tapped(pubkey) }
    }

    private func clearSearch() {
        query = ""
        searchFocused = false
        relaySearch?.cancel()
        searchingRelays = false
    }

    // MARK: - Faces

    /// Pictures for a globe of everyone someone follows: on yours, the
    /// people you interact with most; on anyone else's, a spread of their
    /// follows. Only pictures that have loaded.
    private var ringFaces: [String] {
        guard let frame, frame.center == author, let candidates = faceCandidates[frame.center] else { return [] }
        return TrustMap.pickFaces(candidates) { pictureRenders($0) }
    }

    private func pictureKey(_ pubkey: String) -> String? {
        nostrService.profiles[pubkey]?.pictureURL.map { pubkey + " " + $0.absoluteString }
    }

    private func pictureRenders(_ pubkey: String) -> Bool {
        pictureKey(pubkey).map(renderedPictures.contains) ?? false
    }

    private func prepareFaces(_ key: String, forceProfiles: Bool = false) {
        guard key == author, let ring = frames[key]?.ring else { return }
        let candidates = TrustMap.faceCandidates(ring, engagement: key == me ? engagement : [:])
        faceCandidates[key] = candidates
        nostrService.fetchMissingProfiles(for: candidates, force: forceProfiles)
        loadPictures(candidates)
    }

    /// Loads the candidates' pictures as their profiles arrive, and lets the
    /// globe take the ones that loaded once a second rather than one by one,
    /// so it settles a few times, not sixteen.
    private func loadPictures(_ candidates: [String]) {
        pictureLoader?.cancel()
        pictureLoader = Task {
            var asked: Set<String> = []
            var loaded: Set<String> = []
            for _ in 0..<20 {
                for pubkey in candidates {
                    guard let key = pictureKey(pubkey), !asked.contains(key),
                          !renderedPictures.contains(key),
                          let url = nostrService.profiles[pubkey]?.pictureURL else { continue }
                    asked.insert(key)
                    if AvatarImageCache.shared.image(for: url) != nil {
                        loaded.insert(key)
                    } else {
                        AvatarImageCache.shared.load(url: url) { image in
                            if image != nil { loaded.insert(key) }
                        }
                    }
                }
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                if !loaded.isEmpty {
                    renderedPictures.formUnion(loaded)
                    loaded.removeAll()
                }
            }
        }
    }

    /// Who you interact with, from your own events on the device relay and
    /// the ones aimed at you in its inbox (the seed relays when it isn't up).
    private func loadEngagement(force: Bool = false) async {
        let feed = FeedService.shared
        let local = feed.localRelayURL
        let inbox = feed.localInboxURL
        let outward: [URL] = local.map { [$0] } ?? feed.externalRelayURLs
        let inward: [URL] = inbox.map { [$0] } ?? feed.externalRelayURLs
        let kinds = TrustMap.engagementKinds
        async let mine = ZapHistoryService.query(
            filters: [["authors": [me], "kinds": kinds, "limit": 1000]], relays: outward)
        async let toMe = ZapHistoryService.query(
            filters: [["#p": [me], "kinds": kinds, "limit": 1000]], relays: inward)
        let (mineEvents, toMeEvents) = await (mine, toMe)
        let me = me
        let scores = await Task.detached {
            TrustMap.engagementScores(mine: mineEvents, toMe: toMeEvents, me: me)
        }.value
        engagement = scores
        prepareFaces(me, forceProfiles: force)
    }

    private func recomputeHaze() {
        let graph = FeedService.shared.relayTabTrustedPubkeys().union(arrivals)
        let counts = FeedService.shared.wotVouches
        let inner = myFollows.union([me, author])
        Task.detached(priority: .userInitiated) {
            let shell = TrustMap.haze(graph.subtracting(inner))
            let close = counts.map { v in Set(shell.filter { (v[$0] ?? 0) >= TrustMap.closeVouches }) } ?? []
            await MainActor.run {
                haze = shell
                closeHaze = close
                web = graph
                vouches = counts
                if !TrustMap.layers(hasVouches: counts != nil).contains(layer) { layer = .everyone }
            }
        }
    }

    // MARK: - Breadcrumbs

    private var crumbRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(crumbs.enumerated()), id: \.element) { index, pubkey in
                    if index > 0 { crumbArrow }
                    Button { jump(to: index) } label: { chip(pubkey, on: index == crumbs.count - 1) }
                        .buttonStyle(.plain)
                        .accessibilityHint(Text(index == crumbs.count - 1 ? "" : "Goes back to this step"))
                }
                // On the WOT tab the destination is always you.
                if centerKey != author && !isWOTTab {
                    crumbArrow
                    chip(author, on: false, destination: true)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text("Looking for \(name(author))"))
                }
            }
            .padding(.horizontal)
        }
    }

    private var crumbArrow: some View {
        Text("›").font(.appSystem(size: 13)).foregroundColor(.secondary).accessibilityHidden(true)
    }

    private func chip(_ pubkey: String, on: Bool, destination: Bool = false) -> some View {
        HStack(spacing: 6) {
            AvatarView(url: nostrService.profiles[pubkey]?.pictureURL, pubkey: pubkey, size: 22)
            Text(name(pubkey))
                .font(.appSystem(size: 13))
                .lineLimit(1)
        }
        .padding(.leading, 3)
        .padding(.trailing, 10)
        .padding(.vertical, 3)
        .foregroundColor(destination ? Color.havenPurple : .primary)
        .background(Capsule().fill(on ? Color.havenPurple.opacity(0.22) : Color.white.opacity(0.08)))
        .overlay(Capsule().stroke(destination ? Color.havenPurple.opacity(0.5) : .clear, lineWidth: 1))
    }

    // MARK: - Words

    /// "47", or "at least 5" while relays may hold more: the count is only
    /// the signed lists actually checked, never a number a relay states.
    private func countText(_ frame: Frame) -> String {
        frame.exhausted ? "\(frame.bridges.count)" : "at least \(frame.bridges.count)"
    }

    @ViewBuilder private var explainer: some View {
        if let frame {
            let them = name(author)
            let center = frame.center == me ? nil : name(frame.center)
            let count = Text(countText(frame)).foregroundColor(.havenPurple).bold()
            let direct = frame.ring.contains(author)
            if !frame.listFound {
                Text("No relay checked had \(name(frame.center))'s follow list, so their globe can't be drawn.")
            } else if lookingDeeper.contains(frame.center) {
                Text("Looking two steps further out. This downloads a few MB of follow lists.")
            } else if deeperFailed.contains(frame.center) {
                Text("Couldn't reach the relays to look further out.")
            } else if frame.center == author && author == me && frame.ring.isEmpty {
                Text(loadingMyFollows ? "Loading your follows…"
                     : "No follow list found yet. Follow people and they'll appear here.")
            } else if frame.center == author && author == me {
                // The WOT tab, before anyone is picked.
                Text("Everyone you follow, and your web around them. Tap a face or search to see how someone reaches you.")
            } else if frame.center == author {
                Text("Everyone \(them) follows. Tap a face to see their path.")
            } else if !frame.bridges.isEmpty {
                if let center {
                    let mutual = Text("\(mutualCount(frame))").foregroundColor(.primary).bold()
                    Text("\(center) reaches \(them) through \(count) of their follows. \(mutual) of \(center)'s follows are people you follow too (bright stars).")
                } else if direct {
                    Text("You follow \(them), and so do \(count) people you follow.")
                } else {
                    Text("Followed by \(count) people you follow.")
                }
            } else if direct {
                Text("\(center ?? "You") \(center == nil ? "follow" : "follows") \(them) directly.")
            } else if let chains = frame.chains, !chains.isEmpty {
                let via = Text("\(Set(chains.map(\.via)).count)").foregroundColor(.havenPurple).bold()
                Text("\(via) people who follow \(them) are followed by \(center.map { "people \($0) follows" } ?? "people you follow").")
            } else if frame.chains != nil {
                Text("No longer route turned up in the follow lists checked.")
            } else {
                switch frame.path.reach {
                case .web: Text("In your Web of Trust through people further out. Look deeper to see who.")
                case .outside: Text("Not in your web. No one you follow follows them, in the lists checked.")
                case .unknown where center != nil:
                    Text("None of \(center ?? "")'s follows that were checked follow \(them).")
                case .unknown: Text("Your trust graph hasn't loaded yet.")
                default: Text("Tap a face to follow their path.")
                }
            }
        } else {
            Text("Loading who \(name(centerKey)) follows…")
        }
    }

    /// The globe's words for VoiceOver, which reads the picture as one element.
    private var summary: String {
        guard let frame else { return "Loading who \(name(centerKey)) follows." }
        if frame.center == me && author == me {
            return "You, the \(frame.ring.count) people you follow, and your web around them."
        }
        let them = name(author)
        let who = frame.center == me ? "you follow" : "\(name(frame.center)) follows"
        if frame.bridges.isEmpty {
            return frame.ring.contains(author) ? "\(name(frame.center)) follows \(them) directly." : "No one \(who) was seen following \(them)."
        }
        let named = frame.bridges.prefix(2).map(name).joined(separator: ", ")
        return "\(them) is followed by \(countText(frame)) people \(who), including \(named)."
    }

    private var gestureHint: some View {
        Text("Drag to spin · pinch to zoom · tap a face to follow their path · double-tap to reset")
            .font(.appSystem(size: 11))
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityHidden(true)
    }

    @ViewBuilder private var legend: some View {
        if let frame, frame.listFound {
            HStack(spacing: 6) {
                legendDot(Color(red: 0.72, green: 0.82, blue: 1))
                Text("\(frame.ring.count.formatted()) \(frame.center == me ? "you follow" : "\(name(frame.center)) follows")")
                Spacer(minLength: 8)
                if !frame.bridges.isEmpty {
                    legendDot(.orange)
                    Text("\(countText(frame)) follow \(name(author))")
                        .foregroundColor(.havenPurple)
                }
            }
            .font(.appSystem(size: 12))
            .foregroundColor(.secondary)
            .lineLimit(1)
        }
    }

    // MARK: - Footer (phone) and side panel (iPad, Mac)

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            explainer
                .font(.appSystem(size: 14))
                .foregroundColor(.primary.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            legend
            actions
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private var sidePanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                AvatarView(url: nostrService.profiles[author]?.pictureURL, pubkey: author, size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name(author)).font(.appSystem(size: 19, weight: .semibold)).lineLimit(1)
                    Text(centerKey == me ? "How you're connected" : "How \(name(centerKey)) is connected")
                        .font(.appSystem(size: 13)).foregroundColor(.secondary).lineLimit(1)
                }
            }
            explainer
                .font(.appSystem(size: 15))
                .foregroundColor(.primary.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            legend
            actions
            Divider().overlay(Color.white.opacity(0.12))
            if let frame, !frame.bridges.isEmpty {
                Text("FOLLOWED BY")
                    .font(.appSystem(size: 12, weight: .semibold))
                    .tracking(1.2)
                    .foregroundColor(.secondary)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(frame.bridges, id: \.self) { pubkey in
                            Button { tapped(pubkey) } label: {
                                HStack(spacing: 12) {
                                    AvatarView(url: nostrService.profiles[pubkey]?.pictureURL, pubkey: pubkey, size: 32)
                                    Text(name(pubkey)).foregroundColor(.primary).lineLimit(1)
                                    Spacer(minLength: 4)
                                    Image(systemName: "scope").foregroundColor(.secondary)
                                }
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text("\(name(pubkey)), follows \(name(author))"))
                            .accessibilityHint(Text("Moves them to the middle of the globe"))
                        }
                    }
                }
            } else {
                Spacer()
            }
            gestureHint
        }
        .padding(24)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.black.opacity(0.35))
        .overlay(alignment: .leading) { Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1) }
    }

    @ViewBuilder private var actions: some View {
        if let frame, frame.listFound {
            if deeperFailed.contains(frame.center) {
                secondaryButton("Try again", action: lookDeeper)
            } else if lookingDeeper.contains(frame.center) {
                secondaryButton("Looking further out…", loading: true, action: {})
                    .disabled(true)
            } else if canLookDeeper(frame) {
                secondaryButton("Look deeper", action: lookDeeper)
            } else if canLoadMore(frame) {
                let loading = loadingMore.contains(frame.center)
                secondaryButton(loading ? "Finding more… \(frame.bridges.count) so far"
                                : failed.contains(frame.center) ? "Couldn't reach the relays. Try again"
                                : "Show everyone who follows \(name(author))",
                                loading: loading, action: showEveryone)
                    .disabled(loading)
            }
        }
        if centerKey != me {
            Button { profilePubkey = centerKey } label: {
                Text("View \(name(centerKey))'s profile")
                    .lineLimit(1)
                    .font(.appSystem(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.havenPurple)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    private func secondaryButton(_ title: String, loading: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if loading { ProgressView().controlSize(.small) }
                Text(title).lineLimit(1)
            }
            .font(.appSystem(size: 15, weight: .semibold))
            .foregroundColor(.havenPurple)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func legendDot(_ color: Color) -> some View {
        Circle().fill(color).frame(width: 7, height: 7).accessibilityHidden(true)
    }

    // MARK: - Peek

    private func peekCard(_ pubkey: String) -> some View {
        let follows = myFollows
        let followsAuthor = frame?.bridges.contains(pubkey) == true
            || frame?.chains?.contains { $0.via == pubkey } == true
        let line = [
            pubkey == me ? "You" : follows.contains(pubkey) ? "You follow" : "Not someone you follow",
            pubkey == author ? nil : followsAuthor ? "follows \(name(author))" : "not seen following \(name(author))",
        ].compactMap { $0 }.joined(separator: " · ")
        return HStack(spacing: 10) {
            AvatarView(url: nostrService.profiles[pubkey]?.pictureURL, pubkey: pubkey, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(name(pubkey)).font(.appSystem(size: 14, weight: .semibold)).lineLimit(1)
                Text(line).font(.appSystem(size: 11)).foregroundColor(.secondary).lineLimit(2)
            }
            Spacer(minLength: 4)
            Button("Profile") { profilePubkey = pubkey; peek = nil }
                .font(.appSystem(size: 13, weight: .semibold))
                .foregroundColor(.havenPurple)
                .buttonStyle(.plain)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.ultraThinMaterial))
        .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
        .padding(12)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Trust card (WOT tab)

    private func openCard(_ pubkey: String) {
        peek = nil
        withAnimation(Motion.fade) {
            card = pubkey
            cardPath = nil
        }
        nostrService.fetchMissingProfiles(for: [pubkey])
        Task {
            // From you, whoever is in the middle: which of your follows follow them.
            let found = await TrustPathService.shared.path(for: pubkey)
            guard card == pubkey else { return }
            nostrService.fetchMissingProfiles(for: found.bridges)
            withAnimation(Motion.fade) { cardPath = found }
        }
    }

    private func closeCard() {
        guard card != nil else { return }
        withAnimation(Motion.fade) {
            card = nil
            cardPath = nil
        }
    }

    /// "Can I trust them?": who they are, the people you follow who follow
    /// them (the post card's answer and words), and what you can do about it.
    /// Block sits behind "…" so it can't be hit by accident.
    private func trustCard(_ pubkey: String) -> some View {
        let following = myFollows.contains(pubkey)
        let blocked = ConfigService.shared.activeAccountBlockedHexPubkeys.contains(pubkey)
        let bridges = cardPath?.bridges ?? []
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                AvatarView(url: nostrService.profiles[pubkey]?.pictureURL, pubkey: pubkey, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name(pubkey)).font(.appSystem(size: 17, weight: .semibold)).lineLimit(1)
                    if let nip05 = nostrService.profiles[pubkey]?.nip05, !nip05.isEmpty {
                        Text(nip05).font(.appSystem(size: 13)).foregroundColor(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Button { closeCard() } label: {
                    Image(systemName: "xmark")
                        .font(.appSystem(size: 13, weight: .bold))
                        .foregroundColor(.secondary)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Close"))
            }
            HStack(spacing: 10) {
                if !bridges.isEmpty {
                    HStack(spacing: -10) {
                        ForEach(bridges, id: \.self) { bridge in
                            AvatarView(url: nostrService.profiles[bridge]?.pictureURL, pubkey: bridge, size: 26)
                                .overlay(Circle().stroke(Color.black.opacity(0.6), lineWidth: 2))
                        }
                    }
                    .accessibilityHidden(true)
                }
                Text(TrustPathText.label(cardPath, name: name))
                    .font(.appSystem(size: 13))
                    .foregroundColor(cardPath?.reach == .outside ? .secondary : .primary.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                // The profile page's words: Unfollow says what the tap does.
                cardButton(following ? "Unfollow" : "Follow", icon: following ? "person.badge.minus" : "person.badge.plus",
                           filled: !following) {
                    FollowActions.toggle(pubkey, name: name(pubkey), isFollowing: following)
                }
                cardButton("Message", icon: "message.fill", filled: false) { messagePubkey = pubkey }
                cardButton("Profile", icon: "person.crop.circle", filled: false) { profilePubkey = pubkey }
                Menu {
                    Button(role: blocked ? nil : .destructive) { toggleBlock(pubkey, blocked: blocked) } label: {
                        Label(blocked ? "Unblock" : "Block", systemImage: blocked ? "hand.raised.slash" : "hand.raised")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.appSystem(size: 15, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 40, height: 38)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                        .contentShape(Capsule())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .accessibilityLabel(Text("More"))
            }
            .padding(.leading, 4)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 16, y: 6)
        .padding(12)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }

    private func cardButton(_ title: String, icon: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.appSystem(size: 12, weight: .semibold))
                Text(title).font(.appSystem(size: 14, weight: .semibold)).lineLimit(1)
            }
            .foregroundColor(filled ? .white : .havenPurple)
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .background(Capsule().fill(filled ? Color.havenPurple : Color.white.opacity(0.08)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func toggleBlock(_ pubkey: String, blocked: Bool) {
        guard let data = Data(hex: pubkey), let npub = Bech32.encode(hrp: "npub", data: data) else { return }
        if blocked {
            ConfigService.shared.unblockProfile(npub)
        } else {
            ConfigService.shared.blockProfile(npub)
            closeCard()
        }
    }

    // MARK: - People list (VoiceOver, and anyone who'd rather read)

    private var peopleList: some View {
        NavigationStack {
            List {
                if let frame {
                    if !frame.bridges.isEmpty {
                        Section(frame.center == me ? "People you follow who follow \(name(author))"
                                                   : "\(name(frame.center))'s follows who follow \(name(author))") {
                            ForEach(frame.bridges, id: \.self) { personRow($0) }
                        }
                    }
                    if let chains = frame.chains, !chains.isEmpty {
                        Section("Further out") {
                            ForEach(Array(chains.prefix(50).enumerated()), id: \.offset) { _, chain in
                                Button { showingList = false; profilePubkey = chain.via } label: {
                                    Text("\(name(chain.bridge)) → \(name(chain.via)) → \(name(author))")
                                        .foregroundColor(.primary)
                                }
                            }
                        }
                    }
                    if frame.bridges.isEmpty && (frame.chains ?? []).isEmpty {
                        Text("No one on this globe follows \(name(author)) yet.").foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle(name(centerKey))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { showingList = false } }
            }
        }
    }

    private func personRow(_ pubkey: String) -> some View {
        Button { showingList = false; profilePubkey = pubkey } label: {
            HStack(spacing: 12) {
                AvatarView(url: nostrService.profiles[pubkey]?.pictureURL, pubkey: pubkey, size: 28)
                Text(name(pubkey)).foregroundColor(.primary).lineLimit(1)
            }
        }
        .accessibilityHint(Text("Opens their profile"))
    }

    // MARK: - Actions

    private func tapped(_ pubkey: String) {
        // The WOT tab answers "can I trust them?" in a card and stays on you.
        if isWOTTab { return pubkey == me || pubkey == card ? closeCard() : openCard(pubkey) }
        if peek != nil { peek = nil; return }
        // The one in the middle: say who they are rather than go nowhere.
        if pubkey == centerKey {
            if pubkey != me { peek = pubkey }
            return
        }
        if let index = crumbs.firstIndex(of: pubkey) { return jump(to: index) }
        crumbs.append(pubkey)
        guard frames[pubkey] == nil else { return }
        nostrService.fetchMissingProfiles(for: [pubkey])
        Task {
            let list = await TrustPathService.shared.followList(of: pubkey)
            let ring = list ?? []
            let found = await TrustPathService.shared.path(for: author, from: pubkey, follows: ring)
            frames[pubkey] = Frame(center: pubkey, ring: ring, listFound: list != nil, path: found)
            nostrService.fetchMissingProfiles(for: [pubkey] + found.bridges)
            prepareFaces(pubkey)
        }
    }

    private func jump(to index: Int) {
        guard index < crumbs.count - 1 else { return }
        peek = nil
        crumbs = Array(crumbs.prefix(index + 1))
    }

    /// "Show everyone": batches of 20 lists until no relay has more, lighting
    /// stars as each batch lands. Stops at `TrustMap.maxBatchedLists` a tap.
    private func showEveryone() {
        guard let start = frame, !loadingMore.contains(start.center) else { return }
        let key = start.center
        loadingMore.insert(key)
        failed.remove(key)
        Task {
            var fetched = 0
            while let current = frames[key], !current.exhausted, fetched < TrustMap.maxBatchedLists {
                guard let lists = await TrustPathService.shared.moreBridgeLists(
                    author: author, follows: current.ring, seen: current.seen) else {
                    failed.insert(key)
                    break
                }
                guard var updated = frames[key] else { break }
                fetched += lists.count
                let fresh = TrustPath.allBridges(author: author, me: key, follows: Set(current.ring),
                                                 contactLists: lists)
                updated.seen.formUnion(lists.compactMap { $0["pubkey"] as? String })
                updated.bridges = Array(Set(updated.bridges).union(fresh)).sorted()
                if lists.isEmpty { updated.exhausted = true }
                frames[key] = updated
            }
            if let lit = frames[key]?.bridges {
                nostrService.fetchMissingProfiles(for: TrustMap.spread(lit, count: TrustGlobeCanvas.maxFaces))
            }
            loadingMore.remove(key)
        }
    }

    private func lookDeeper() {
        guard let start = frame, !lookingDeeper.contains(start.center) else { return }
        let key = start.center
        lookingDeeper.insert(key)
        deeperFailed.remove(key)
        Task {
            let graph = key == me ? FeedService.shared.relayTabTrustedPubkeys() : []
            let chains = await TrustPathService.shared.deeperChains(author: author, center: key,
                                                                    follows: start.ring, trustGraph: graph)
            if let chains {
                frames[key]?.chains = chains
                nostrService.fetchMissingProfiles(
                    for: chains.prefix(TrustMap.shownChains).flatMap { [$0.bridge, $0.via] })
            } else {
                deeperFailed.insert(key)
            }
            lookingDeeper.remove(key)
        }
    }

    // MARK: - Helpers

    private func canLoadMore(_ frame: Frame) -> Bool {
        !frame.exhausted && !frame.bridges.isEmpty
            && (frame.path.hasMore || frame.bridges.count > TrustPath.shownBridges)
    }

    /// No one at the core's follows follows the author: offer the two-step
    /// search further out, which costs a few MB, so only on a tap.
    private func canLookDeeper(_ frame: Frame) -> Bool {
        frame.bridges.isEmpty && frame.chains == nil && frame.center != author
            && !frame.ring.contains(author)
    }

    private func mutualCount(_ frame: Frame) -> Int {
        frame.ring.filter(myFollows.contains).count
    }

    private func avatar(_ pubkey: String, _ size: CGFloat) -> AnyView {
        AnyView(AvatarView(url: nostrService.profiles[pubkey]?.pictureURL, pubkey: pubkey, size: size))
    }

    private func name(_ pubkey: String) -> String {
        if pubkey == me { return "You" }
        return nostrService.profiles[pubkey]?.bestName ?? "npub…" + String(pubkey.suffix(6))
    }
}

/// The globe on its own, from a post's WOT button. Finds the path the same way
/// Event Info's Trust Path card does, then shows the globe once it lands.
struct TrustWebSheet: View {
    let author: String
    @Environment(\.dismiss) private var dismiss

    @State private var path: TrustPath?

    init(author: String, path: TrustPath? = nil) {
        self.author = author
        _path = State(initialValue: path)
    }

    /// iPad: the globe gets the whole screen, where a sheet would box it in.
    static var opensFullScreen: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad
        #else
        false
        #endif
    }

    var body: some View {
        NavigationStack {
            Group {
                if let path {
                    TrustWebView(author: author, path: path)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(GlobeSpace())
                        .environment(\.colorScheme, .dark)
                        .navigationTitle("Web of Trust")
                        #if os(iOS)
                        .navigationBarTitleDisplayMode(.inline)
                        #endif
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        // A Mac sheet sizes to its content, and the globe has none of its own.
        .frame(minWidth: 820, minHeight: 600)
        #endif
        .task(id: author) {
            guard path == nil else { return }
            path = await TrustPathService.shared.path(for: author)
        }
    }
}

extension View {
    /// Opens the Web of Trust globe: full screen on iPad, a sheet elsewhere.
    func trustWebPresentation(isPresented: Binding<Bool>, author: String, path: TrustPath? = nil) -> some View {
        modifier(TrustWebPresentation(isPresented: isPresented, author: author, path: path))
    }
}

private struct TrustWebPresentation: ViewModifier {
    @Binding var isPresented: Bool
    let author: String
    let path: TrustPath?

    func body(content: Content) -> some View {
        #if os(iOS)
        if TrustWebSheet.opensFullScreen {
            content.fullScreenCover(isPresented: $isPresented) { TrustWebSheet(author: author, path: path) }
        } else {
            content.sheet(isPresented: $isPresented) { TrustWebSheet(author: author, path: path) }
        }
        #else
        content.sheet(isPresented: $isPresented) { TrustWebSheet(author: author, path: path) }
        #endif
    }
}

/// Deep space behind the globe.
struct GlobeSpace: View {
    static let edge = Color.black

    var body: some View {
        RadialGradient(colors: [Color(red: 0.07, green: 0.08, blue: 0.13), Self.edge],
                       center: .center, startRadius: 40, endRadius: 900)
            .ignoresSafeArea()
    }
}

/// The globe itself: one Canvas, with a frame clock that runs only while
/// something on it moves. Real pictures are Canvas symbols, so a frame never
/// lays out a view.
struct TrustGlobeCanvas: View {
    let frame: TrustWebView.Frame?
    let center: String
    let me: String
    let author: String
    let myFollows: Set<String>
    let haze: [String]
    /// The part of the haze at least `TrustMap.closeVouches` of your follows follow.
    var closeHaze: Set<String> = []
    /// Follows drawn as faces when the core is the person everyone is
    /// measured against (your own globe on the WOT tab).
    let ringFaces: [String]
    /// False while a sheet covers the globe: the clock stops.
    let running: Bool
    /// Which part of the web is lit (the WOT tab's layer picker).
    var layer: TrustMap.Layer = .everyone
    let summary: String
    let avatar: (String, CGFloat) -> AnyView
    let name: (String) -> String
    let onTap: (String) -> Void
    /// The person the trust card is about: the globe turns to face them.
    var focus: String? = nil
    /// A tap that lands on no one, e.g. to close the peek card.
    var onEmptyTap: () -> Void = {}

    /// Bridges drawn as faces; the rest stay bright stars.
    static let maxFaces = 12
    /// Spinning and turning to a person both take about this long; a new
    /// person's globe settles in after it.
    private static let turnDelay: Duration = .milliseconds(380)

    @StateObject private var scene = GlobeScene()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appIsActive = true
    @State private var lastDrag: CGSize = .zero
    @State private var pinchBase: CGFloat = 1
    /// Reset by SwiftUI when a gesture ends *or is cancelled*; `onEnded` is
    /// skipped on cancel, so this is what puts the camera back to rest.
    @GestureState private var dragActive = false
    @GestureState private var pinchActive = false

    private struct LoadKey: Hashable {
        let center: String
        let ring: Int
        let bridges: Int
        let chains: Int
        let haze: Int
        let close: Int
        let mine: Int
        /// Who is in the ring, not just how many: a follow and an unfollow
        /// together keep the count.
        let ringHash: Int
        /// Who is in the haze: past its cap, a newcomer swaps in for someone
        /// at the margin and the count stays put.
        let hazeHash: Int
        let faces: [String]
    }

    private var loadKey: LoadKey? {
        frame.map {
            LoadKey(center: $0.center, ring: $0.ring.count, bridges: $0.bridges.count,
                    chains: $0.chains?.count ?? -1, haze: haze.count, close: closeHaze.count, mine: myFollows.count,
                    ringHash: $0.ring.hashValue, hazeHash: haze.hashValue, faces: ringFaces)
        }
    }

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation(minimumInterval: nil, paused: !scene.awake || !running || !appIsActive)) { timeline in
                Canvas { context, size in
                    scene.tick(now: timeline.date.timeIntervalSinceReferenceDate)
                    scene.draw(in: &context, size: size, accent: .orange, name: name)
                } symbols: {
                    ForEach(scene.faceKeys, id: \.self) { key in
                        avatar(key, GlobeScene.pictureSize).tag(key)
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(drag.simultaneously(with: magnify))
            .simultaneousGesture(taps(in: geo.size))
            .accessibilityElement()
            .accessibilityLabel(Text("Web of Trust globe"))
            .accessibilityValue(Text(summary))
            .accessibilityHint(Text("Swipe up or down to zoom. Actions go to a person."))
            .accessibilityAdjustableAction { direction in
                let range = GlobeCamera.zoomRange
                let step = direction == .increment ? 0.3 : -0.3
                scene.camera.zoomTarget = min(range.upperBound, max(range.lowerBound, scene.camera.zoomTarget + step))
                scene.camera.touch(at: Date.timeIntervalSinceReferenceDate)
                scene.wake()
            }
            .accessibilityActions {
                ForEach(scene.faceKeys.filter { $0 != center }, id: \.self) { key in
                    Button("Go to \(name(key))") { onTap(key) }
                }
                Button("Reset view") { scene.reset() }
            }
        }
        .onAppear {
            scene.reduceMotion = reduceMotion
            scene.focus(layer)
        }
        .onChange(of: layer) { _, layer in scene.focus(layer) }
        .onChange(of: focus) { _, key in if let key { scene.turn(to: key) } }
        .onChange(of: reduceMotion) { _, reduced in
            scene.reduceMotion = reduced
            if reduced { scene.camera.spin = .zero }
            scene.wake()
        }
        .onChange(of: center) { _, key in scene.turn(to: key) }
        .onChange(of: dragActive) { _, active in
            guard !active else { return }
            scene.camera.dragging = false
            lastDrag = .zero
            scene.wake()
        }
        .onChange(of: pinchActive) { _, active in
            if !active { pinchBase = 1 }
        }
        .onReceive(NotificationCenter.default.publisher(for: AppActivity.didBecomeActive)) { _ in appIsActive = true }
        .onReceive(NotificationCenter.default.publisher(for: AppActivity.willResignActive)) { _ in appIsActive = false }
        .task(id: loadKey) {
            guard let frame else { return }
            // Turn to the new person first, then let the globe re-settle around them.
            if scene.hasLoaded, frame.center != scene.center, !reduceMotion {
                try? await Task.sleep(for: Self.turnDelay)
                guard !Task.isCancelled else { return }
            }
            scene.load(frame, me: me, author: author, myFollows: myFollows, haze: haze, closeHaze: closeHaze,
                       ringFaces: ringFaces)
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 2)
            .updating($dragActive) { _, active, _ in active = true }
            .onChanged { value in
                let now = Date.timeIntervalSinceReferenceDate
                scene.camera.dragging = true
                scene.camera.drag(dx: value.translation.width - lastDrag.width,
                                  dy: value.translation.height - lastDrag.height, at: now)
                lastDrag = value.translation
                scene.wake()
            }
            .onEnded { value in
                scene.camera.dragging = false
                lastDrag = .zero
                scene.camera.flick(vx: value.velocity.width, vy: value.velocity.height,
                                   at: Date.timeIntervalSinceReferenceDate, reduceMotion: reduceMotion)
                scene.wake()
            }
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .updating($pinchActive) { _, active, _ in active = true }
            .onChanged { value in
                let range = GlobeCamera.zoomRange
                let zoom = scene.camera.zoomTarget * Double(value.magnification / pinchBase)
                scene.camera.zoomTarget = min(range.upperBound, max(range.lowerBound, zoom))
                scene.camera.touch(at: Date.timeIntervalSinceReferenceDate)
                pinchBase = value.magnification
                scene.wake()
            }
            .onEnded { _ in pinchBase = 1 }
    }

    /// A double-tap resets; a single tap waits until it can't be one, so a
    /// double-tap on a face doesn't also fly there.
    private func taps(in size: CGSize) -> some Gesture {
        SpatialTapGesture(count: 2)
            .onEnded { _ in scene.reset() }
            .exclusively(before: SpatialTapGesture().onEnded { tap in
                guard let key = scene.hit(tap.location, in: size) else { return onEmptyTap() }
                #if os(iOS)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                #endif
                onTap(key)
            })
    }
}

/// Everything the globe draws, as flat arrays so a frame is one pass with no
/// lookups. Mutated by the frame clock; only `awake` and `faceKeys` publish.
@MainActor
final class GlobeScene: ObservableObject {
    enum Kind { case ring, mutual, haze, closeHaze, bridge, via }

    /// False once nothing moves: the frame clock stops until a touch or new data.
    @Published private(set) var awake = true
    /// Who is drawn with a picture: the core, the author, and the faces.
    @Published private(set) var faceKeys: [String] = []

    /// Pictures are drawn from a symbol this size, scaled to each face.
    static let pictureSize: CGFloat = 64
    /// A new globe fades and glides in over this long, then holds still.
    private static let settleTime: TimeInterval = 1.8

    var camera = GlobeCamera()
    var reduceMotion = false
    private(set) var center = ""
    private(set) var hasLoaded = false
    private var author = ""
    private var me = ""
    private var bridges: [String] = []
    private var chains: [TrustMap.Chain] = []
    private var faces: [String] = []
    /// Faces that are follows on someone's own globe: drawn in the ring's colour.
    private var ringFaceSet: Set<String> = []
    /// Faces drawn with a picture last frame, so they keep their seat.
    private var seated: Set<String> = []
    private var direct = false
    /// How brightly your follows (x), the Close shell (y) and the rest of the
    /// shell (z) are drawn, easing toward the picked layer's
    /// (`TrustMap.layerWeights`).
    private var weights = SIMD3<Double>(1, 1, 1)
    private var weightTarget = SIMD3<Double>(1, 1, 1)

    private var keys: [String] = []
    private var dirs: [SIMD3<Double>] = []
    private var kinds: [Kind] = []
    private var isFace: [Bool] = []
    private var radius: [Double] = []
    private var radiusTarget: [Double] = []
    private var alpha: [Double] = []
    private var alphaTarget: [Double] = []
    private var index: [String: Int] = [:]

    private var born: TimeInterval = 0
    private var threadsBorn: TimeInterval = 0
    private var threadProgress = 1.0
    private var settling = false
    private var lastTick: TimeInterval?
    private var sleepQueued = false

    // MARK: Data

    func load(_ frame: TrustWebView.Frame, me: String, author: String, myFollows: Set<String>, haze: [String],
              closeHaze: Set<String> = [], ringFaces: [String] = []) {
        let now = Date.timeIntervalSinceReferenceDate
        let newCenter = !hasLoaded || frame.center != center
        self.me = me
        self.author = author
        center = frame.center

        // Every star's shell and look for this core.
        let bridgeSet = Set(frame.bridges)
        var want: [String: (Kind, Double)] = [:]
        if frame.center == me {
            for key in haze { want[key] = (closeHaze.contains(key) ? .closeHaze : .haze, TrustMap.outerRadius) }
        }
        for key in frame.ring {
            let kind: Kind = bridgeSet.contains(key) ? .bridge
                : frame.center != me && myFollows.contains(key) ? .mutual : .ring
            want[key] = (kind, TrustMap.ringRadius)
        }
        for chain in frame.chains ?? [] where want[chain.via]?.0 != .bridge {
            want[chain.via] = (.via, TrustMap.outerRadius)
        }
        // A bridge the ring snapshot missed (the follow list changed or
        // loaded late) still gets its star and thread.
        for key in frame.bridges where want[key] == nil { want[key] = (.bridge, TrustMap.ringRadius) }
        want[author] = (.bridge, TrustMap.authorRadius)
        want[frame.center] = (.ring, 0)

        for i in keys.indices where want[keys[i]] == nil {
            radiusTarget[i] = 2.4      // drifts out and fades
            alphaTarget[i] = 0
        }
        for (key, (kind, r)) in want {
            if let i = index[key] {
                kinds[i] = kind
                radiusTarget[i] = r
                alphaTarget[i] = 1
            } else {
                index[key] = keys.count
                keys.append(key)
                dirs.append(TrustMap.direction(of: key))
                kinds.append(kind)
                isFace.append(false)
                radius.append(r)
                radiusTarget.append(r)
                alpha.append(0)
                alphaTarget.append(1)
            }
        }

        direct = frame.center != author && frame.ring.contains(author)
        bridges = frame.center == author ? [] : frame.bridges
        chains = frame.chains ?? []
        var shown: [String] = []
        var taken: Set<String> = [frame.center, author]
        for key in TrustMap.spread(bridges, count: TrustGlobeCanvas.maxFaces) where taken.insert(key).inserted {
            shown.append(key)
        }
        for chain in chains.prefix(TrustMap.shownChains) {
            for key in [chain.bridge, chain.via] where taken.insert(key).inserted { shown.append(key) }
        }
        // Someone's own globe has no paths to draw: their follows get the faces.
        let ringSet = Set(frame.ring)
        ringFaceSet = []
        if frame.center == author {
            for key in ringFaces where ringSet.contains(key) && taken.insert(key).inserted {
                shown.append(key)
                ringFaceSet.insert(key)
            }
        }
        faces = shown
        let pictured = Set(shown).union([frame.center, author])
        for i in keys.indices { isFace[i] = pictured.contains(keys[i]) }
        let symbols = (frame.center == author ? [author] : [frame.center, author]) + shown
        if faceKeys != symbols { faceKeys = symbols }

        born = now
        settling = true
        if newCenter {
            threadsBorn = now
            threadProgress = reduceMotion ? 1 : 0
            let target = GlobeCamera.facing(TrustMap.direction(of: frame.center == author ? frame.center : author))
            if hasLoaded {
                camera.fly(to: target, at: now)
            } else {
                // Opens already turned to show the paths.
                camera.orientation = target
                camera.touch(at: now)
            }
        }
        hasLoaded = true
        if reduceMotion { settle() }
        wake()
    }

    /// Turn toward someone tapped, before their globe has loaded.
    func turn(to key: String) {
        camera.fly(to: GlobeCamera.facing(TrustMap.direction(of: key)), at: Date.timeIntervalSinceReferenceDate)
        wake()
    }

    func reset() {
        let target = center == author ? center : author
        camera.fly(to: GlobeCamera.facing(TrustMap.direction(of: target)), at: Date.timeIntervalSinceReferenceDate)
        wake()
    }

    /// Lights one layer and dims the rest. Nothing is reloaded.
    func focus(_ layer: TrustMap.Layer) {
        weightTarget = TrustMap.layerWeights(layer)
        if reduceMotion { weights = weightTarget }
        wake()
    }

    func wake() {
        sleepQueued = false
        if !awake {
            lastTick = nil
            awake = true
        }
    }

    // MARK: Frame clock

    func tick(now: TimeInterval) {
        let dt = lastTick.map { min(GlobeCamera.maxStep, max(0, now - $0)) } ?? 0
        lastTick = now
        camera.step(dt: dt, now: now, reduceMotion: reduceMotion)
        let fading = weights != weightTarget
        if fading {
            weights += (weightTarget - weights) * (1 - exp(-dt * 8))
            if simd_reduce_max(abs(weightTarget - weights)) < 0.005 { weights = weightTarget }
        }
        if settling {
            let age = now - born
            let glide = 1 - exp(-dt * 7), fade = 1 - exp(-dt * 6)
            for i in keys.indices {
                radius[i] += (radiusTarget[i] - radius[i]) * glide
                // Sweep in by direction so the shell fills like a wave, not a pop.
                if age > (dirs[i].x + 1) * 0.12 { alpha[i] += (alphaTarget[i] - alpha[i]) * fade }
            }
            threadProgress = min(1, max(0, (now - threadsBorn - 0.35) / 0.55))
            if age > Self.settleTime { settle() }
        }
        if !settling, !fading, !camera.wantsFrames(now: now, reduceMotion: reduceMotion), awake, !sleepQueued {
            // Not from inside the draw: publishing mid-update is undefined.
            sleepQueued = true
            DispatchQueue.main.async { [weak self] in
                guard let self, self.sleepQueued else { return }
                self.sleepQueued = false
                self.awake = false
            }
        }
    }

    /// Land every star where it's heading and drop the ones that faded out.
    private func settle() {
        radius = radiusTarget
        alpha = alphaTarget
        threadProgress = 1
        settling = false
        let keep = keys.indices.filter { alphaTarget[$0] > 0 }
        guard keep.count < keys.count else { return }
        keys = keep.map { keys[$0] }
        dirs = keep.map { dirs[$0] }
        kinds = keep.map { kinds[$0] }
        isFace = keep.map { isFace[$0] }
        radius = keep.map { radius[$0] }
        radiusTarget = keep.map { radiusTarget[$0] }
        alpha = keep.map { alpha[$0] }
        alphaTarget = keep.map { alphaTarget[$0] }
        index = Dictionary(uniqueKeysWithValues: keys.enumerated().map { ($1, $0) })
    }

    // MARK: Projection

    struct Projected {
        let point: CGPoint
        /// Toward the viewer: about −1.6 (back of the outer shell) to 1.6.
        let depth: Double
        let scale: Double
        /// 0 at the back of the globe, 1 at the front.
        var front: Double { min(1, max(0, (depth + 1.7) / 3.4)) }
    }

    /// One camera's projection, worked out once per frame.
    private struct Projector {
        let turn: simd_double3x3
        let cameraZ: Double
        let unit: Double
        let mid: CGPoint

        init(_ camera: GlobeCamera, size: CGSize) {
            turn = simd_double3x3(camera.orientation)
            cameraZ = 4.2 / camera.zoom
            unit = Double(min(size.width, size.height)) * 0.40 * 4.2 * 0.92
            mid = CGPoint(x: size.width / 2, y: size.height / 2)
        }

        func callAsFunction(_ p: SIMD3<Double>) -> Projected? {
            let v = turn * p
            let gap = cameraZ - v.z
            // Zoomed in, the outer shell passes the camera: drop what's behind the lens.
            guard gap >= 0.45 else { return nil }
            let s = 1 / gap
            return Projected(point: CGPoint(x: mid.x + v.x * s * unit, y: mid.y - v.y * s * unit),
                             depth: v.z, scale: s * cameraZ)
        }
    }

    private func position(_ key: String, _ project: Projector) -> Projected? {
        guard let i = index[key] else { return nil }
        return project(dirs[i] * radius[i])
    }

    /// Closest front-facing face to a tap, within reach of a fingertip.
    /// Zoomed in, plain stars can be tapped too.
    func hit(_ point: CGPoint, in size: CGSize) -> String? {
        let project = Projector(camera, size: size)
        var best: (key: String, distance: CGFloat)?
        func consider(_ i: Int, reach: CGFloat) {
            guard alpha[i] > 0.5, let p = project(dirs[i] * radius[i]), p.depth > -0.15 else { return }
            let d = hypot(p.point.x - point.x, p.point.y - point.y)
            if d < reach, d < (best?.distance ?? .infinity) { best = (keys[i], d) }
        }
        for i in keys.indices where isFace[i] { consider(i, reach: 30) }
        if best == nil, camera.zoom >= 1.6 {
            for i in keys.indices where !isFace[i] && kinds[i] != .haze && kinds[i] != .closeHaze { consider(i, reach: 16) }
        }
        return best?.key
    }

    // MARK: Drawing

    private static let ringColor = Color(red: 0.72, green: 0.82, blue: 1)
    private static let hazeColor = Color(red: 0.62, green: 0.55, blue: 0.9)
    /// Warm amber for the threads, lighter than the glow behind them.
    private static let threadColor = Color(red: 1, green: 0.66, blue: 0.3)
    /// Star brightness is rounded to this many steps, so each kind of star
    /// is a handful of fills however many people there are. Fine enough that
    /// the faint haze keeps its front-to-back depth.
    private static let levels = 40

    func draw(in context: inout GraphicsContext, size: CGSize, accent: Color, name: (String) -> String) {
        guard hasLoaded, let centerIndex = index[center] else { return }
        let project = Projector(camera, size: size)
        let zoom = camera.zoom
        let k = min(1, min(size.width, size.height) / 620)
        let view = CGRect(origin: .zero, size: size).insetBy(dx: -8, dy: -8)
        guard let core = project(dirs[centerIndex] * radius[centerIndex]) else { return }
        let origin = project(.zero) ?? core
        let coreR = 22 * k * core.scale * min(zoom, 1.8)

        // Glow behind the core.
        context.fill(Path(ellipseIn: CGRect(x: origin.point.x - coreR * 3, y: origin.point.y - coreR * 3,
                                            width: coreR * 6, height: coreR * 6)),
                     with: .radialGradient(Gradient(colors: [accent.opacity(0.32), .clear]),
                                           center: origin.point, startRadius: 0, endRadius: coreR * 3))

        // Stars, bucketed by kind and brightness: one pass, a few fills.
        enum Slot: Int, CaseIterable { case haze, ring, mutual, hot }
        var buckets = Array(repeating: Array(repeating: Path(), count: Self.levels + 1), count: Slot.allCases.count)
        var labelled: [(key: String, at: CGPoint, r: Double, a: Double)] = []
        let namesOut = zoom > 2.2
        for i in keys.indices where !isFace[i] {
            let a = alpha[i] * (kinds[i] == .haze ? weights.z : kinds[i] == .closeHaze ? weights.y : weights.x)
            guard a > 0.02, let p = project(dirs[i] * radius[i]), view.contains(p.point) else { continue }
            let front = p.front
            let slot: Slot, base: Double, size: Double
            switch kinds[i] {
            case .haze: (slot, base, size) = (.haze, 0.06 + 0.16 * front, 1.2)
            // A touch brighter and bigger: close enough to tell apart in the shell.
            case .closeHaze: (slot, base, size) = (.haze, 0.10 + 0.22 * front, 1.4)
            case .ring: (slot, base, size) = (.ring, 0.25 + 0.65 * front, 2.1)
            case .mutual: (slot, base, size) = (.mutual, 0.45 + 0.55 * front, 2.4)
            case .bridge, .via: (slot, base, size) = (.hot, 0.35 + 0.65 * front, 2.8)
            }
            let level = Int((min(1, base * a) * Double(Self.levels)).rounded())
            guard level > 0 else { continue }
            let r = size * p.scale * zoom
            buckets[slot.rawValue][min(Self.levels, level)]
                .addEllipse(in: CGRect(x: p.point.x - r, y: p.point.y - r, width: 2 * r, height: 2 * r))
            if namesOut, slot != .haze, p.depth > 0.6, labelled.count < 200 {
                labelled.append((keys[i], p.point, r, a))
            }
        }
        func fill(_ slot: Slot, _ color: Color) {
            for level in 1...Self.levels where !buckets[slot.rawValue][level].isEmpty {
                context.fill(buckets[slot.rawValue][level],
                             with: .color(color.opacity(Double(level) / Double(Self.levels))))
            }
        }
        fill(.haze, Self.hazeColor)
        fill(.ring, Self.ringColor)
        fill(.mutual, .white)

        // Threads: core → bridge → author, drawn out over half a second.
        // Glow for every front thread goes in one blurred layer.
        let authorP = center == author ? nil : position(author, project)
        if let authorP {
            let t = threadProgress
            let leg1 = min(1, t * 2), leg2 = max(0, t * 2 - 1)
            var glow = Array(repeating: Path(), count: 4), dashed = Path()
            var strong = Array(repeating: Path(), count: 4), faint = Array(repeating: Path(), count: 4)
            func band(_ front: Double) -> Int { min(3, Int(front * 4)) }
            if direct {
                var p = Path()
                p.move(to: core.point)
                p.addLine(to: lerp(core.point, authorP.point, t))
                strong[3].addPath(p)
                glow[3].addPath(p)
            }
            for key in bridges {
                guard let i = index[key], alpha[i] > 0.05, let b = project(dirs[i] * radius[i]) else { continue }
                var inner = Path()
                inner.move(to: core.point)
                inner.addLine(to: lerp(core.point, b.point, leg1))
                faint[band(b.front)].addPath(inner)
                var outer = Path()
                if leg2 > 0 {
                    outer.move(to: b.point)
                    outer.addLine(to: lerp(b.point, authorP.point, leg2))
                    strong[band(b.front)].addPath(outer)
                }
                if b.front > 0.62 {
                    glow[band(b.front)].addPath(inner)
                    glow[band(b.front)].addPath(outer)
                }
            }
            if t >= 1 {
                for chain in chains {
                    guard let b = position(chain.bridge, project), let v = position(chain.via, project) else { continue }
                    dashed.move(to: core.point)
                    dashed.addLine(to: b.point)
                    dashed.addLine(to: v.point)
                    dashed.addLine(to: authorP.point)
                }
            }
            // Glow brightens toward the front, still in one blurred layer.
            func bandAlpha(_ level: Int) -> Double {
                let front = (Double(level) + 0.5) / 4
                return 0.10 + 0.75 * front * front
            }
            if glow.contains(where: { !$0.isEmpty }) {
                context.drawLayer { layer in
                    layer.addFilter(.blur(radius: 5))
                    for level in 0..<4 where !glow[level].isEmpty {
                        layer.stroke(glow[level], with: .color(accent.opacity(bandAlpha(level) * 0.6)), lineWidth: 3)
                    }
                }
            }
            for level in 0..<4 {
                let a = bandAlpha(level)
                if !faint[level].isEmpty {
                    context.stroke(faint[level], with: .color(Self.threadColor.opacity(a * 0.45)), lineWidth: 0.8)
                }
                if !strong[level].isEmpty {
                    context.stroke(strong[level], with: .color(Self.threadColor.opacity(a)), lineWidth: 1.3)
                }
            }
            if !dashed.isEmpty {
                context.stroke(dashed, with: .color(Self.threadColor.opacity(0.7)),
                               style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round, dash: [5, 4]))
            }
        }
        fill(.hot, accent)

        // Faces, back to front: bridges, chain steps and the author.
        var drawn: [(key: String, p: Projected, tint: Color, size: Double)] = []
        for key in faces {
            guard let p = position(key, project) else { continue }
            if ringFaceSet.contains(key) {
                drawn.append((key, p, Self.ringColor, 14))
            } else {
                drawn.append((key, p, accent, 15))
            }
        }
        if let authorP { drawn.append((author, authorP, .yellow, 24)) }
        drawn.sort { $0.p.depth < $1.p.depth }

        // Seats: a face only where it covers no other face and not the core;
        // the rest stay stars until the globe turns them some room.
        let spots = drawn.reversed().filter { $0.p.depth >= -0.1 || $0.key == author }.map {
            TrustMap.FaceSpot(key: $0.key, x: $0.p.point.x, y: $0.p.point.y,
                              r: $0.size * k * $0.p.scale * min(zoom, 1.8))
        }
        let seats = TrustMap.seatFaces(spots, always: [author], kept: seated,
                                       blocked: [TrustMap.FaceSpot(key: center, x: core.point.x, y: core.point.y, r: coreR)])
        seated = seats

        // Labels: front-most first, skipping any that would cover one placed.
        // Pictures count as placed too, so a name never runs across a face.
        var placed = [CGRect(x: core.point.x - 40, y: core.point.y - coreR, width: 80, height: coreR * 2 + 22)]
            + spots.filter { seats.contains($0.key) }.map { CGRect(x: $0.x - $0.r, y: $0.y - $0.r, width: 2 * $0.r, height: 2 * $0.r) }
        var showLabel = Set<String>()
        let labelCap = zoom < 1.5 ? 9 : 40
        for face in drawn.reversed() where face.p.depth > 0.15 && seats.contains(face.key) && showLabel.count < labelCap {
            let r = face.size * k * face.p.scale * min(zoom, 1.8)
            let box = CGRect(x: face.p.point.x - 46, y: face.p.point.y + r + 2, width: 92, height: 16)
            if face.key == author || !placed.contains(where: { $0.intersects(box) }) {
                placed.append(box)
                showLabel.insert(face.key)
            }
        }
        for face in drawn {
            let a = alpha[index[face.key] ?? centerIndex] * (face.key == author ? 1 : weights.x)
            let dim = (0.35 + 0.65 * face.p.front) * a
            let r = face.size * k * face.p.scale * min(zoom, 1.8)
            if face.p.depth < -0.1 && face.key != author {
                // Behind the globe: a warm ember, not a face.
                let e = 3.2 * face.p.scale * zoom
                context.fill(Path(ellipseIn: CGRect(x: face.p.point.x - e, y: face.p.point.y - e, width: 2 * e, height: 2 * e)),
                             with: .color(face.tint.opacity(dim)))
                continue
            }
            if !seats.contains(face.key) {
                // No room for its picture here: a bright star in its colour.
                let e = 3.6 * face.p.scale * zoom
                context.fill(Path(ellipseIn: CGRect(x: face.p.point.x - e, y: face.p.point.y - e, width: 2 * e, height: 2 * e)),
                             with: .color(face.tint.opacity(dim)))
                continue
            }
            drawFace(&context, key: face.key, at: face.p.point, r: r, tint: face.tint, opacity: dim, name: name)
            if showLabel.contains(face.key) {
                let text = context.resolve(Text(name(face.key))
                    .font(.system(size: face.key == author ? 14 : 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9 * dim)))
                context.draw(text, at: CGPoint(x: face.p.point.x, y: face.p.point.y + r + 10))
            }
        }

        // Names on plain stars once zoomed well in, where they fit.
        if namesOut {
            for star in labelled where placed.count < 60 {
                let box = CGRect(x: star.at.x - 40, y: star.at.y + star.r + 2, width: 80, height: 13)
                guard !placed.contains(where: { $0.intersects(box) }) else { continue }
                placed.append(box)
                let text = context.resolve(Text(name(star.key)).font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.6 * star.a)))
                context.draw(text, at: CGPoint(x: star.at.x, y: star.at.y + star.r + 8))
            }
        }

        // The core last: it is always in front of its own shell.
        drawFace(&context, key: center, at: core.point, r: coreR, tint: center == me ? accent : .white,
                 opacity: 1, name: name)
        let label = context.resolve(Text(name(center)).font(.system(size: 13, weight: .bold)).foregroundColor(.white))
        context.draw(label, at: CGPoint(x: core.point.x, y: core.point.y + coreR + 11))
    }

    private func drawFace(_ context: inout GraphicsContext, key: String, at p: CGPoint, r: Double,
                          tint: Color, opacity: Double, name: (String) -> String) {
        var c = context
        c.opacity = opacity
        let rect = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
        c.fill(Path(ellipseIn: rect.insetBy(dx: -r * 0.9, dy: -r * 0.9)),
               with: .radialGradient(Gradient(colors: [tint.opacity(0.35), .clear]),
                                     center: p, startRadius: r * 0.6, endRadius: r * 1.9))
        if let picture = c.resolveSymbol(id: key) {
            c.draw(picture, in: rect)
        } else {
            // No picture yet: a colour of their own and their first initial.
            let hue = index[key].map { (dirs[$0].x + 1) / 2 } ?? 0
            c.fill(Path(ellipseIn: rect), with: .color(Color(hue: hue, saturation: 0.45, brightness: 0.62)))
            let initial = c.resolve(Text(String(name(key).prefix(1)))
                .font(.system(size: r * 0.95, weight: .bold, design: .rounded)).foregroundColor(.white))
            c.draw(initial, at: p)
        }
        c.stroke(Path(ellipseIn: rect), with: .color(tint), lineWidth: max(1.2, r * 0.12))
    }

    private func lerp(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }
}

/// The one-line summary shared by the card and the expanded view.
enum TrustPathText {
    static func label(_ path: TrustPath?, name: (String) -> String) -> String {
        guard let path else { return "Tracing how they reach you…" }
        switch path.reach {
        case .you:
            return "This is you."
        case .follow:
            return path.bridges.isEmpty
                ? "You follow them · 1 hop"
                : "You follow them · also followed by \(bridgeNames(path, name: name))"
        case .bridged:
            return "Followed by \(bridgeNames(path, name: name)) you follow · 2 hops"
        case .web:
            return "In your Web of Trust"
        case .outside:
            return "Not in your web · no one you follow follows them"
        case .unknown:
            return "Your trust graph isn't loaded yet"
        }
    }

    private static func bridgeNames(_ path: TrustPath, name: (String) -> String) -> String {
        let names = path.bridges.prefix(2).map(name)
        let rest = path.bridges.count - names.count
        if rest > 0 || path.hasMore { return names.joined(separator: ", ") + " + more" }
        return names.joined(separator: " and ")
    }
}

/// The relay's report on a web-of-trust rebuild (`WotRefreshProgressC`).
struct WotRefresh: Decodable {
    let running: Bool
    let phase: String
    let batches: Int
    let batchesDone: Int
    let lists: Int
    let size: Int
    /// People this rebuild has found so far, and how many of them weren't on
    /// the old map. Missing from a relay older than the live fill.
    let found: Int?
    let new: Int?

    static func progress() -> WotRefresh? {
        guard let pointer = WotRefreshProgressC() else { return nil }
        defer { free(pointer) }
        return try? JSONDecoder().decode(WotRefresh.self, from: Data(String(cString: pointer).utf8))
    }

    /// The running (or last) rebuild's newcomers from index `from` on, and
    /// how many there are in all (`WotNewcomersC`). Pass the last total back
    /// in to get only the people found since.
    static func newcomers(from: Int) -> Newcomers? {
        guard let pointer = WotNewcomersC(Int32(clamping: from)) else { return nil }
        defer { free(pointer) }
        return try? JSONDecoder().decode(Newcomers.self, from: Data(String(cString: pointer).utf8))
    }

    struct Newcomers: Decodable {
        let total: Int
        let pubkeys: [String]
    }

    /// How far through the rebuild, 0 to 1. A relay can take a minute to
    /// answer, so inside a phase the bar creeps toward the next one with
    /// time and never reaches it until the relay says so.
    func fraction(phaseSeconds: TimeInterval) -> Double {
        let creep = 1 - exp(-phaseSeconds / 25)
        switch phase {
        case "follows": return 0.02 + 0.2 * creep
        case "lists":
            let done = batches == 0 ? 0 : Double(batchesDone) / Double(batches)
            let next = batches == 0 ? 1 : Double(batchesDone + 1) / Double(batches)
            return 0.25 + 0.7 * (done + (min(1, next) - done) * creep)
        case "counting": return 0.97
        default: return 1
        }
    }

    var caption: String {
        switch phase {
        case "follows": return "Reading your follow list…"
        // The relay counts lists per batch, so a running count sat still.
        case "lists":
            return batches > 1 ? "Reading your follows' lists… part \(min(batchesDone + 1, batches)) of \(batches)"
                : "Reading your follows' lists…"
        case "counting": return "Counting who your web trusts…"
        case "saved": return "Your web: \(size.formatted()) people"
        default: return "Rebuild stopped. Showing your last saved web."
        }
    }
}
