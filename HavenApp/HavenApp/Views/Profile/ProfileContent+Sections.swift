import SwiftUI
import Combine
import ImageIO
#if os(iOS)
import Photos
#endif

extension ProfileContent {
    // MARK: - Section tab bar

    var sectionTabBar: some View {
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
    func revealLateSections() {
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
    var sectionContent: some View {
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
    func olderPageSentinel(itemCount: Int) -> some View {
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
        // Once the opening load is in, page back for this tab by itself, and
        // again whenever a page finishes (it may have been another tab's).
        .task(id: "\(section.rawValue)-\(opening)-\(pagingNow)") {
            guard !opening, !pagingNow else { return }
            loader.autoPageEmptyTab(section)
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

}
