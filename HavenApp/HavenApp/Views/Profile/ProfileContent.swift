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
struct ProfileContent<Badge: View, Actions: View, ShopHeader: View, ScrollDecoration: ViewModifier>: View {
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
    /// Applied to the scroll view itself (pull-to-edit needs its geometry).
    let scrollDecoration: ScrollDecoration
    @ViewBuilder let badge: () -> Badge
    /// Called with 0, 1, 2: each a tighter row, for when the wider one does
    /// not fit on one line.
    @ViewBuilder let actions: (_ compact: Int) -> Actions
    @ViewBuilder let shopHeader: () -> ShopHeader

    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var configService: ConfigService
    /// Not observed: the main feed changes many times a second while it
    /// loads, and observing all of it redrew this page each time.
    /// `feedWatch` redraws only for the parts this page shows.
    private var feedService: FeedService { .shared }
    @StateObject private var feedWatch = ProfileFeedWatch()
    /// Likes, reposts, replies and zap sats under each post.
    @ObservedObject private var engagementStore = ProfileEngagementStore.shared
    @Environment(\.openURL) private var openURL

    @State private var showingNoteDetail: FeedNote?
    /// Non-nil when an iPad split pane owns the note detail column.
    @Environment(\.noteDetailSelection) private var noteDetailSelection
    /// True when this profile is a sheet or a pushed page. Sheets inherit the
    /// environment, so without this a profile opened over the split would
    /// select into the detail column hidden behind it.
    @Environment(\.isPresented) private var isPresented
    @State private var showingProfileKey: IdentifiableString?
    @State private var showingMediaUrl: IdentifiableURL?
    @Namespace private var mediaZoom
    @State private var selectedMedia: MediaItem? = nil
    @State private var dragOffset: CGSize = .zero
    #if os(iOS)
    @State private var saveToPhotosMessage: String? = nil
    #endif
    #if os(macOS)
    @State private var keyMonitor: Any? = nil
    #endif
    @State private var copiedNpub = false
    @State private var copiedLightning = false
    /// Reply or quote from a row.
    @State private var composeContext: ComposeContext?

    /// The Following / Followers page, open on the tab that was tapped.
    @State private var followListTab: FollowListTab?
    /// The viewer's follower ledger, read before the page opens.
    @State private var viewerLedger: FollowerSnapshot?

    /// The late tabs on show. Set only when their loader finishes, so the
    /// tab bar re-spaces once instead of once per tab as each one arrives.
    @State private var revealedSections = Set<ProfileSection>()
    /// Set once the profile has waited long enough for its metadata; the
    /// header stops holding space for a bio that is not coming.
    @State private var metadataWaitOver = false
    /// Height of the profile's scroll view. A section is at least this tall,
    /// so picking one with a single item keeps the tabs where they were and
    /// leaves blank space below, instead of the page snapping back down.
    @State private var viewportHeight: CGFloat = 0
    /// Width of the scroll view; the banner's height follows it.
    @State private var viewportWidth: CGFloat = 0
    /// Height of the bars above the scroll view's content, which the banner
    /// reaches up under.
    @State private var topInset: CGFloat = 0
    /// The topmost note on screen, which the scroll view keeps in place.
    @State private var scrolledNoteID: String?
    @State private var showingArticle: ArticleRoute?
    @State private var musicSheet: MusicSheet?
    @State private var selectedListing: MarketListing?

    private static var topID: String { "profile-top" }

    private var profile: FeedProfile? {
        nostrService.profiles[pubkey]
    }

    private var selectedSection: ProfileSection { loader.selectedSection }

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
                            .environment(\.feedActions, .make(feedService: feedService, nostrService: nostrService))
                            .tabBarBottomPadding()
                            .frame(minHeight: viewportHeight, alignment: .top)
                    }
                    .frame(maxWidth: 720)
                    .frame(maxWidth: .infinity)
                }
            }
            // Holds the note you are reading in place while notes arrive from
            // each relay and are sorted in above it, and while rows above it
            // grow as their media loads. The main feed does the same.
            .scrollPosition(id: $scrolledNoteID)
            .scrollDirectionTracking(feedService: feedService)
            .onGeometryChange(for: CGSize.self) { $0.size } action: {
                viewportHeight = $0.height
                viewportWidth = $0.width
            }
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { topInset = $0 }
            // The banner draws its own scrim under the bar; the system edge would
            // lay a grey band over it.
            .hiddenTopScrollEdge()
            .modifier(scrollDecoration)
            .onChange(of: scrollToTopToken) { _, _ in
                scrolledNoteID = nil
                withAnimation(Motion.fade) { proxy.scrollTo(Self.topID, anchor: .top) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.platformWindowBackground.ignoresSafeArea())
        .onAppear {
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
                VStack(spacing: 6) {
                    FollowNotificationBanner()
                    ZapNotificationBanner()
                    ErrorNotificationBanner()
                }
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
    private func openNote(_ note: FeedNote) {
        if let noteDetailSelection, !isPresented {
            noteDetailSelection.select(note)
        } else {
            showingNoteDetail = note
        }
    }

    // MARK: - Banner

    /// A strip a third as tall as it is wide, the same with or without a
    /// banner (a tinted wash stands in), so nothing below it moves when the
    /// profile or its banner arrives.
    private var bannerHeight: CGFloat {
        let width = viewportWidth > 0 ? viewportWidth : 390
        return min(max(width / 3, 110), 210)
    }

    private var bannerHeader: some View {
        ProfileBannerView(
            bannerURL: profile?.bannerURL,
            avatarURL: profile?.pictureURL,
            pubkey: pubkey,
            height: bannerHeight,
            topInset: topInset,
            onTap: { url in showingMediaUrl = IdentifiableURL(url: url) }
        )
        .overlay(alignment: .top) {
            if let dismissAction { dismissHeader(dismissAction) }
        }
    }

    /// Sits on the banner, so it carries its own dark disc instead of relying
    /// on the page behind it.
    private func dismissHeader(_ action: @escaping () -> Void) -> some View {
        HStack {
            Spacer()
            Button(action: action) {
                Image(systemName: "xmark.circle.fill")
                    .font(.appSystem(size: 24))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white.opacity(0.9), .black.opacity(0.45))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.platformSeparator.opacity(0.6))
            .frame(height: 0.5)
            .padding(.vertical, 16)
    }

    // MARK: - Header block

    private var headerBlock: some View {
        HStack(alignment: .top, spacing: 14) {
            AvatarView(url: profile?.pictureURL, pubkey: pubkey, size: 72)
                .overlay(
                    Circle().stroke(Color.havenPurple.opacity(0.35), lineWidth: 1.5)
                )
                // A ring in the page color lifts the avatar off the banner.
                .padding(3)
                .background(Circle().fill(Color.platformWindowBackground))
                // Half over the banner; the name column stays below it.
                .padding(.top, -36)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(profile?.bestName ?? ProfileFormat.shortPubkey(pubkey))
                        .font(.appSystem(size: 20, weight: .bold))
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    if let nip05 = profile?.nip05, !nip05.isEmpty {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.appSystem(size: 13))
                            .foregroundColor(Color.havenVerified)
                    }

                    Spacer(minLength: 0)

                    badge()
                }

                if let nip05 = profile?.nip05, !nip05.isEmpty {
                    Text(nip05)
                        .font(.appSystem(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                } else if awaitingMetadata {
                    Text("name@example.com")
                        .font(.appSystem(size: 12))
                        .foregroundColor(.secondary)
                        .redacted(reason: .placeholder)
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    // MARK: - Metadata placeholders

    /// No kind 0 for this person yet. The header holds the space the NIP-05
    /// line, a short bio and the Lightning row usually take, so the tabs and
    /// notes are not pushed down when they arrive.
    private var awaitingMetadata: Bool {
        guard !metadataWaitOver else { return false }
        guard let p = profile else { return true }
        return p.name == nil && p.displayName == nil && p.about == nil
            && p.pictureURL == nil && p.nip05 == nil && p.lud16 == nil
    }

    private var bioPlaceholder: some View {
        Text("A short bio about this person, about as long as most are, two lines.")
            .font(.appSystem(size: 13))
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .redacted(reason: .placeholder)
            .accessibilityHidden(true)
    }

    private var linksPlaceholder: some View {
        linkChip("name@wallet.example", icon: "bolt.fill", tint: .secondary)
            .redacted(reason: .placeholder)
            .accessibilityHidden(true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 12)
    }

    // MARK: - Bio

    private func bioBlock(_ about: String) -> some View {
        Text(about)
            .font(.appSystem(size: 13))
            .foregroundColor(.primary.opacity(0.85))
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 12)
    }

    // MARK: - Action row

    /// One line, never scrolled. When space runs out (small phones, large
    /// text) the screen's own row drops words, tightest last.
    private var actionRow: some View {
        ViewThatFits(in: .horizontal) {
            actions(0).fixedSize(horizontal: false, vertical: true)
            actions(1).fixedSize(horizontal: false, vertical: true)
            actions(2).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Follow counts

    /// One line under the links. The Notes and Media counts already sit on
    /// their tabs, so only the two that open somewhere else are here.
    private var followCountsRow: some View {
        HStack(spacing: 18) {
            Button { openFollowList(.following) } label: {
                followCount(loader.followingCountShown.map(ProfileFormat.shortInt) ?? "—", label: "Following")
            }
            Button { openFollowList(.followers) } label: {
                followCount(loader.displayedFollowersCount.map(ProfileFormat.shortInt) ?? "—", label: "Followers")
            }
            Spacer(minLength: 0)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private func followCount(_ value: String, label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value)
                .font(.appSystem(size: 14, weight: .bold))
                .monospacedDigit()
                .foregroundColor(.primary)
            Text(label)
                .font(.appSystem(size: 13))
                .foregroundColor(.secondary)
        }
        .lineLimit(1)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    // MARK: - Follow lists

    /// Reads the viewer's ledger first, then opens. Opening first built the
    /// page without it: your own Followers showed the relays' sample with a
    /// "load more", then swapped to the full list a moment later.
    private func openFollowList(_ tab: FollowListTab) {
        let viewer = configService.activeAccountHexPubkey
        Task.detached(priority: .userInitiated) {
            let ledger = FollowerSnapshot.load(owner: viewer)
            await MainActor.run {
                viewerLedger = ledger
                followListTab = tab
            }
        }
    }

    private func followListPage(startOn tab: FollowListTab) -> some View {
        let ledger = viewerLedger
        let viewerFollowers = ledger.map { Set($0.current.map(\.pubkey)) } ?? []
        let spam = ledger.map { Set($0.followers.filter(\.isSpam).map(\.pubkey)) } ?? []
        // Your own followers come from the relay's ledger, which is complete.
        // Anyone else's are what relays returned, which may be short.
        let ownLedger = loader.usesOwnLedger ? ledger : nil
        let followers: [String: Int64] = ownLedger.map { snap in
            Dictionary(snap.current.map { ($0.pubkey, $0.existing ? $0.listAt : $0.followedAt) }, uniquingKeysWith: max)
        } ?? loader.followerSeenAt
        let haveMore = ownLedger == nil && !loader.followersExhausted
            && (loader.displayedFollowersCount ?? 0) > followers.count
        return FollowListView(
            subject: pubkey,
            subjectName: profile?.bestName ?? ProfileFormat.shortPubkey(pubkey),
            startOn: tab,
            following: loader.followingPubkeys,
            followers: followers,
            followersHaveMore: haveMore,
            followerPagesDone: loader.followerPagesDone,
            followersTotal: ownLedger == nil ? loader.displayedFollowersCount : nil,
            isViewersOwnFollowers: ownLedger != nil,
            followsViewer: viewerFollowers,
            hidden: spam,
            onLoadMoreFollowers: ownLedger == nil ? { loader.loadMoreFollowers() } : nil
        )
        .environmentObject(nostrService)
        .environmentObject(configService)
    }

    // MARK: - Links

    private var lightningAddress: String? {
        guard let profile else { return nil }
        if let lud06 = profile.lud06, !lud06.isEmpty { return "lnurl:" + lud06 }
        if let lud16 = profile.lud16, !lud16.isEmpty { return lud16 }
        return nil
    }

    private var formattedNpub: String {
        if let npub = ProfileFormat.npub(pubkey) {
            return String(npub.prefix(12)) + "…" + String(npub.suffix(8))
        }
        return "npub…" + String(pubkey.suffix(8))
    }

    /// Lightning address, website and npub, one wrapping row of chips in
    /// place of a table row each. Tap copies, or opens the website.
    private var linksRow: some View {
        ProfileChipFlow(spacing: 8) {
            if let lud16 = lightningAddress {
                Button { ProfileFormat.copy(lud16); flash($copiedLightning) } label: {
                    linkChip(lud16, icon: copiedLightning ? "checkmark" : "bolt.fill",
                             tint: copiedLightning ? .green : .orange)
                }
                .accessibilityLabel(copiedLightning ? "Lightning address copied" : "Copy Lightning address \(lud16)")
            }
            if let website = profile?.website, !website.isEmpty,
               let url = URL(string: website.hasPrefix("http") ? website : "https://\(website)") {
                let shown = website.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
                Button { openURL(url) } label: {
                    linkChip(shown, icon: "globe", tint: .havenPurple)
                }
                .accessibilityLabel("Open \(shown)")
            }
            Button {
                if let npub = ProfileFormat.npub(pubkey) { ProfileFormat.copy(npub); flash($copiedNpub) }
            } label: {
                linkChip(formattedNpub, icon: copiedNpub ? "checkmark" : "key.fill",
                         tint: copiedNpub ? .green : .secondary)
            }
            .accessibilityLabel(copiedNpub ? "Public key copied" : "Copy public key")
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private func flash(_ flag: Binding<Bool>) {
        flag.wrappedValue = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            flag.wrappedValue = false
        }
    }

    private func linkChip(_ text: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.appSystem(size: 10, weight: .bold))
                .foregroundColor(tint)
            Text(text)
                .font(.appSystem(size: 12, weight: .medium))
                .foregroundColor(.primary.opacity(0.8))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Capsule().fill(Color.secondary.opacity(0.1)))
        .contentShape(Capsule())
    }

    // MARK: - Section tab bar

    private var sectionTabBar: some View {
        HStack(spacing: 0) {
            ForEach(visibleSections) { section in
                Button(action: {
                    // No animation: the old and new sections cross-faded at
                    // different heights, and the page jumped while they did.
                    var instant = Transaction()
                    instant.disablesAnimations = true
                    withTransaction(instant) {
                        // The other section's notes are not this one's: an
                        // anchor left over would pull the page to it.
                        scrolledNoteID = nil
                        loader.selectedSection = section
                    }
                }) {
                    VStack(spacing: 6) {
                        // Icons only, no names (Logen): icon and count, or the
                        // icon alone on a tab too narrow for the count.
                        ViewThatFits(in: .horizontal) {
                            tabLabel(section, showsCount: true)
                            tabLabel(section, showsCount: false)
                        }
                        .foregroundColor(selectedSection == section ? .havenPurple : .secondary)

                        Rectangle()
                            .fill(selectedSection == section ? Color.havenPurple : Color.clear)
                            .frame(height: 2)
                    }
                    .padding(.top, 4)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(section.rawValue))
                .accessibilityValue(Text(countLabel(for: section)))
                #if os(macOS)
                .help(section.rawValue)
                #endif
            }
        }
        .padding(.horizontal, 16)
    }

    private func tabLabel(_ section: ProfileSection, showsCount: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: section.symbol)
                .font(.appSystem(size: 14, weight: .semibold))
            let count = countLabel(for: section)
            if showsCount, !count.isEmpty {
                Text(count)
                    .font(.appSystem(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .lineLimit(1)
        .fixedSize()
        .frame(height: 20)
    }

    /// Shop only shows when this person has listings, or on your own profile
    /// where it holds the Sell button, so most profiles keep five tabs.
    private var visibleSections: [ProfileSection] {
        ProfileSection.allCases.filter { section in
            switch section {
            case .shop: return shopAlwaysVisible || revealedSections.contains(.shop)
            // Only when this person has some, so most profiles keep five tabs.
            case .articles, .divines, .music: return revealedSections.contains(section)
            default: return true
            }
        }
    }

    /// Shows the late tabs that have content, all at once. Runs when a
    /// loader finishes; a tab already on show stays while a refresh runs.
    private func revealLateSections() {
        var next = revealedSections
        if !extras.isLoading {
            next.subtract([.articles, .divines, .music])
            if !extras.articles.isEmpty { next.insert(.articles) }
            if !extras.reels.isEmpty { next.insert(.divines) }
            if !extras.tracks.isEmpty { next.insert(.music) }
        }
        if !shop.isLoading {
            if shop.listings.isEmpty { next.remove(.shop) } else { next.insert(.shop) }
        }
        guard next != revealedSections else { return }
        revealedSections = next
        if !visibleSections.contains(selectedSection) { loader.selectedSection = .notes }
    }

    private func count(for section: ProfileSection) -> Int {
        switch section {
        case .shop: return shop.listings.count
        case .articles: return extras.articles.count
        case .divines: return extras.reels.count
        case .music: return extras.tracks.count
        default: return loader.notes(for: section).count
        }
    }

    /// "48", or "48+" while older pages may still raise it. These are the
    /// notes loaded, not totals.
    private func countLabel(for section: ProfileSection) -> String {
        let n = count(for: section)
        guard n > 0 else { return "" }
        return loader.hasMore(for: section) ? ProfileFormat.shortInt(n) + "+" : ProfileFormat.shortInt(n)
    }

    // MARK: - Section content

    @ViewBuilder
    private var sectionContent: some View {
        switch selectedSection {
        case .shop: shopSection
        case .articles: articlesSection
        case .divines: divinesSection
        case .music: musicSection
        default: noteSectionContent
        }
    }

    // MARK: - Articles, diVines, music

    private var articlesSection: some View {
        LazyVStack(spacing: 12) {
            ForEach(extras.articles) { article in
                ArticleCardView(note: article, profile: profile)
                    .contentShape(Rectangle())
                    .onTapGesture { showingArticle = ArticleRoute(note: article) }
            }
        }
        .padding(16)
    }

    private var divinesSection: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 4)], spacing: 4) {
            ForEach(extras.reels) { reel in
                ZStack(alignment: .bottomLeading) {
                    Color.black
                    if let poster = reel.posterURL {
                        RetryableAsyncImage(url: poster, contentMode: .fill, targetSize: CGSize(width: 300, height: 530))
                    } else {
                        VideoThumbnailView(url: reel.videoURL, mimeType: reel.mimeType)
                    }
                    Image(systemName: "play.fill")
                        .font(.appSystem(size: 12, weight: .bold))
                        .foregroundColor(.white)
                        .shadow(radius: 3)
                        .padding(6)
                }
                .aspectRatio(9.0 / 16.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
                .onTapGesture {
                    let urls = extras.reels.map(\.videoURL)
                    showingMediaUrl = IdentifiableURL(url: reel.videoURL, allURLs: urls)
                }
                .accessibilityLabel(Text(reel.title ?? "diVine"))
                .accessibilityAddTraits(.isButton)
            }
        }
        .padding(16)
    }

    private var musicSection: some View {
        MusicTrackList(tracks: extras.tracks, sheet: $musicSheet)
            .padding(16)
    }

    private var shopSection: some View {
        VStack(spacing: 14) {
            shopHeader()
            if shop.listings.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: sectionEmptyIcon)
                        .font(.appSystem(size: 24, weight: .thin))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text(shop.isLoading ? "Loading…" : shopEmptyText)
                        .font(.appSystem(size: 12))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 36)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    ForEach(shop.listings) { listing in
                        MarketplaceCardView(listing: listing, profile: profile)
                            .onTapGesture { selectedListing = listing }
                    }
                }
            }
        }
        .padding(16)
    }

    // MARK: - Notes

    @ViewBuilder
    private var noteSectionContent: some View {
        let notes = loader.currentSectionNotes
        if notes.isEmpty {
            emptyNoteSection
        } else if selectedSection == .media {
            mediaGrid(notes: notes)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(Array(notes.enumerated()), id: \.element.id) { idx, note in
                    if idx > 0 {
                        Rectangle()
                            .fill(Color.platformSeparator.opacity(0.4))
                            .frame(height: 0.5)
                            .padding(.leading, 16)
                    }
                    FeedNoteRow(
                        note: note,
                        profile: selectedSection == .tagged
                            ? nostrService.profiles[note.pubkey]
                            : profile,
                        rowData: FeedNoteRowData.resolve(
                            for: note,
                            feedService: feedService,
                            nostrService: nostrService
                        ).with(engagement: engagementStore.engagement(for: feedService.originalNote(for: note).id)),
                        onReply: {
                            if note.kind == 6, let refId = note.repostedEventId,
                               let original = feedService.findNote(id: refId) {
                                composeContext = ComposeContext(replyTo: original, quoteTo: nil)
                            } else {
                                composeContext = ComposeContext(replyTo: note, quoteTo: nil)
                            }
                        },
                        onQuote: {
                            composeContext = ComposeContext(replyTo: nil, quoteTo: feedService.quoteTarget(for: note))
                        },
                        onProfile: { tapped in
                            // This page already shows that profile.
                            guard tapped != pubkey else { return }
                            showingProfileKey = IdentifiableString(id: tapped)
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

                olderPageSentinel(itemCount: notes.count)
            }
            // Numbers under each post, fetched as the posts appear. The tagged
            // tab is other people's posts, so it is left out.
            .task(id: selectedSection == .tagged ? [] : notes.map(\.id)) {
                guard selectedSection != .tagged else { return }
                await engagementStore.load(ids: notes.map { feedService.originalNote(for: $0).id }, author: pubkey)
            }
            .scrollTargetLayout()
            .padding(.top, 4)
        }
    }

    /// Infinite scroll: asks for the page before the oldest note when the
    /// end of the list comes on screen.
    @ViewBuilder
    private func olderPageSentinel(itemCount: Int) -> some View {
        if loader.hasMore(for: selectedSection) && itemCount > 0 {
            Color.clear
                .frame(height: 1)
                .onAppear { loader.loadOlder(for: selectedSection) }
            if loader.isLoadingOlder(for: selectedSection) {
                ProgressView()
                    .scaleEffect(0.6)
                    .tint(Color.havenPurple)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
        }
    }

    /// Nothing in this tab yet. The opening load is the newest 50 posts, so a
    /// tab can be empty while older pages still hold some (replies, reposts,
    /// media): it pages back on its own, and offers to look further when the
    /// automatic rounds run out. "No replies yet" only once nothing older is
    /// left.
    private var emptyNoteSection: some View {
        let section = selectedSection
        let opening = loader.isLoadingNotes || !loader.notesLoadStarted
        let olderLeft = loader.canPageOlder(for: section)
        let pagingNow = loader.isLoadingOlder(for: section)
        return VStack(spacing: 10) {
            Image(systemName: sectionEmptyIcon)
                .font(.appSystem(size: 24, weight: .thin))
                .foregroundColor(.secondary.opacity(0.5))
            Text(opening || pagingNow ? "Loading…"
                 : olderLeft ? "None in the latest posts"
                 : "No \(section.rawValue.lowercased()) yet")
                .font(.appSystem(size: 12))
                .foregroundColor(.secondary)
            if opening || pagingNow {
                ProgressView()
                    .scaleEffect(0.6)
                    .tint(Color.havenPurple)
            } else if olderLeft {
                Button("Look further back") { loader.loadOlder(for: section) }
                    .font(.appSystem(size: 12, weight: .semibold))
                    .foregroundColor(.havenPurple)
                    .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        // Once the opening load is in, page back for this tab by itself.
        .task(id: "\(section.rawValue)-\(opening)") {
            guard !opening, olderLeft else { return }
            loader.loadOlder(for: section)
        }
    }

    private var sectionEmptyIcon: String {
        switch selectedSection {
        case .notes: return "text.bubble"
        case .media: return "photo"
        case .replies: return "arrowshape.turn.up.left"
        default: return selectedSection.symbol
        }
    }

    // MARK: - Media

    private var displayMedia: [MediaItem] {
        let items: [(url: URL, note: FeedNote)] = loader.buckets.media.flatMap { note in
            note.mediaURLs.map { (url: $0, note: note) }
        }
        return items.map { item in
            let ext = item.url.pathExtension.lowercased()
            var isGIF = ext == "gif"
            var isVideo = SupportedMediaFormats.videoExtensions.contains(ext)
            var isAudio = SupportedMediaFormats.audioExtensions.contains(ext)

            if let cachedMime = MediaTypeDetector.shared.getCachedContentType(for: item.url) {
                isGIF = MediaTypeDetector.shared.isGIFContentType(cachedMime)
                isVideo = MediaTypeDetector.shared.isVideoContentType(cachedMime)
                isAudio = cachedMime.lowercased().hasPrefix("audio/")
            }

            let type: MediaItem.MediaType = isVideo ? .video : (isAudio ? .audio : .image)
            let mime = isGIF ? "image/gif" : (isVideo ? "video/mp4" : nil)

            return MediaItem(
                id: UUID.deterministic(from: item.url.absoluteString),
                url: item.url,
                type: type,
                dateAdded: item.note.createdAt,
                pubkey: item.note.pubkey,
                tags: item.note.tags,
                mimeType: mime
            )
        }
    }

    private var isPresentingViewer: Binding<Bool> {
        Binding(
            get: { selectedMedia != nil },
            set: { presenting in
                if !presenting {
                    selectedMedia = nil
                    dragOffset = .zero
                }
            }
        )
    }

    private func mediaGrid(notes: [FeedNote]) -> some View {
        #if os(macOS)
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)
        let gridSpacing: CGFloat = 8
        #else
        // Three across on a phone; a wider pane (iPad, either orientation)
        // gets more tiles rather than three stretched ones. 16 is the grid's
        // own horizontal padding, below.
        let gridSpacing: CGFloat = 6
        let columns = AdaptiveLayout.columns(width: viewportWidth - 16, ideal: 180,
                                             spacing: gridSpacing, minimum: 3, maximum: 6)
        #endif

        let items = displayMedia

        return VStack(spacing: 0) {
            LazyVGrid(columns: columns, spacing: gridSpacing) {
                ForEach(items) { mediaItem in
                    // Your own files get the Vault grid's Delete menu; only a
                    // Blossom file (named by its hash) can be deleted.
                    let hash = canDeleteMedia ? MediaCacheService.blossomHash(in: mediaItem.url) : nil
                    MediaGridItem(
                        item: mediaItem,
                        onDeleteFromMirrors: hash.map { hash in { _ in deleteFromMirrors(hash: hash) } },
                        onDeleteEverywhere: hash.map { hash in { _ in deleteEverywhere(hash: hash) } }
                    ) {
                        withAnimation(Motion.fade) {
                            selectedMedia = mediaItem
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 2)

            olderPageSentinel(itemCount: items.count)
        }
    }

    private func deleteFromMirrors(hash: String) {
        Task {
            await MediaBackupActions.deleteFromMirrors(hash: hash, configService: configService, nostrService: nostrService)
        }
    }

    /// The tile stays: it belongs to a post, and the post is still up unless
    /// "Delete file and post" was chosen (see `.havenOwnEventsDeleted`).
    private func deleteEverywhere(hash: String) {
        Task {
            await MediaBackupActions.deleteEverywhere(hash: hash, configService: configService, nostrService: nostrService)
        }
    }

    @ViewBuilder
    private func mediaViewerContent(for item: MediaItem) -> some View {
        ZStack {
            Color.black.opacity(0.9 * max(0, 1.0 - (abs(dragOffset.height) / 300.0)))
                .edgesIgnoringSafeArea(.all)
                .onTapGesture {
                    withAnimation(Motion.fade) {
                        selectedMedia = nil
                        dragOffset = .zero
                    }
                }

            VStack {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        if configService.hasExternalShareURL(for: item.url) {
                            Button(action: {
                                PlatformClipboard.copy(item.shareURL(with: configService).absoluteString)
                            }) {
                                Image(systemName: "doc.on.doc")
                                    .font(.appSystem(size: 16, weight: .semibold))
                                    .padding(10)
                                    .background(Color.white.opacity(0.1))
                                    .cornerRadius(8)
                            }
                            .buttonStyle(.plain)
                        }

                        #if os(iOS)
                        if item.type == .image || item.type == .video {
                            Button(action: {
                                saveMediaToPhotos(item: item)
                            }) {
                                Image(systemName: "square.and.arrow.down")
                                    .font(.appSystem(size: 16, weight: .semibold))
                                    .padding(10)
                                    .background(Color.white.opacity(0.1))
                                    .cornerRadius(8)
                            }
                            .buttonStyle(.plain)
                        }
                        #endif

                        SourceIndicatorView(url: item.url)

                        Spacer()

                        Button(action: {
                            withAnimation(Motion.fade) {
                                selectedMedia = nil
                                dragOffset = .zero
                            }
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.appTitle)
                                .foregroundColor(.white.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                    }
                    #if os(iOS)
                    if let message = saveToPhotosMessage {
                        Text(message)
                            .font(.appCaption)
                            .foregroundColor(message.contains("Saved") ? .green : .red)
                            .transition(.opacity)
                    }
                    #endif
                }
                .padding()
                .opacity(max(0, 1.0 - (abs(dragOffset.height) / 100.0)))

                Spacer()

                MediaPagerView(items: displayMedia, selection: $selectedMedia, enableKeyboardNavigation: true, showsPositionBar: false) { mediaItem in
                    ViewerViewMediaItem(mediaItem: mediaItem)
                        #if os(iOS)
                        .transition(.opacity.animation(Motion.media))
                        #endif
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .offset(y: dragOffset.height)
                .scaleEffect(max(0.8, 1.0 - (abs(dragOffset.height) / 1000.0)))
                .gesture(
                    DragGesture()
                        .onChanged { gesture in
                            if abs(gesture.translation.height) > abs(gesture.translation.width) || dragOffset.height != 0 {
                                dragOffset = CGSize(width: 0, height: gesture.translation.height)
                            }
                        }
                        .onEnded { gesture in
                            if abs(dragOffset.height) > 120 {
                                withAnimation(Motion.dismiss) {
                                    selectedMedia = nil
                                    dragOffset = .zero
                                }
                            } else {
                                withAnimation(Motion.snapBack) {
                                    dragOffset = .zero
                                }
                            }
                        }
                )

                Spacer()

                Text(item.shareURL(with: configService).absoluteString)
                    .font(.appCaption.monospaced())
                    .foregroundColor(.secondary)
                    .padding(.bottom)
                    .opacity(max(0, 1.0 - (abs(dragOffset.height) / 100.0)))
            }
        }
        .transition(.opacity)
        #if os(iOS)
        .background(ClearFullScreenBackground())
        #endif
    }

    @ViewBuilder
    private var fullScreenOverlay: some View {
        #if os(macOS)
        if let item = selectedMedia {
            mediaViewerContent(for: item)
        }
        #endif
    }

    #if os(iOS)
    private func saveMediaToPhotos(item: MediaItem) {
        saveToPhotosMessage = nil

        Task {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                await MainActor.run {
                    saveToPhotosMessage = "Photo library access denied"
                }
                return
            }

            let session = URLSession(configuration: .default, delegate: LocalhostTrustDelegate(), delegateQueue: nil)
            do {
                let (data, _) = try await session.data(from: item.url)

                if item.type == .video {
                    let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
                    try data.write(to: tempURL)
                    try await PHPhotoLibrary.shared().performChanges {
                        PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: tempURL, options: nil)
                    }
                    try? FileManager.default.removeItem(at: tempURL)
                } else {
                    try await PHPhotoLibrary.shared().performChanges {
                        let request = PHAssetCreationRequest.forAsset()
                        let options = PHAssetResourceCreationOptions()
                        request.addResource(with: .photo, data: data, options: options)
                    }
                }

                await MainActor.run {
                    withAnimation { saveToPhotosMessage = "Saved to Photos" }
                    Task {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        await MainActor.run { withAnimation { saveToPhotosMessage = nil } }
                    }
                }
            } catch {
                await MainActor.run {
                    saveToPhotosMessage = "Failed to save media"
                }
            }
        }
    }
    #endif

    #if os(macOS)
    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard selectedMedia != nil else { return event }
            switch event.keyCode {
            case 123: // left arrow
                navigateMedia(direction: -1)
                return nil
            case 124: // right arrow
                navigateMedia(direction: 1)
                return nil
            case 53: // escape
                withAnimation(Motion.fade) { selectedMedia = nil }
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }
    #endif

    private func navigateMedia(direction: Int) {
        guard let current = selectedMedia,
              let index = displayMedia.firstIndex(where: { $0.id == current.id }) else { return }
        let newIndex = index + direction
        guard displayMedia.indices.contains(newIndex) else { return }
        withAnimation(Motion.fade) { selectedMedia = displayMedia[newIndex] }
    }
}

private extension View {
    @ViewBuilder
    func hiddenTopScrollEdge() -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            self.scrollEdgeEffectHidden(true, for: .top)
        } else {
            self
        }
    }
}
