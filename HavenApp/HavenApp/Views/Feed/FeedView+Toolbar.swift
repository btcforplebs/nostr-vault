import SwiftUI

extension FeedView {
    // MARK: - Feed Leading Toolbar

    #if os(iOS)
    /// The top bar folds with the bottom tab bar: scrolling down leaves only
    /// the connection dot on the left and the feed-style button on the right,
    /// and scrolling up brings the rest back. iPhone only — iPad has a sidebar
    /// instead of the bottom bar this pairs with.
    var isCompactWidth: Bool { horizontalSizeClass == .compact }

    /// One tap target: the whole pill opens the feed picker, with the feed
    /// dashboard at the bottom of it. The icon names the current feed.
    /// Folded, only the icon's circle is left.
    var feedLeadingToolbar: some View {
        // Its own Equatable view so the open menu is only rebuilt when the
        // feed or connection status changes. Built inline, every FeedService
        // publish (each arriving note) re-rendered the menu while it was open,
        // which stalled or jumped its scrolling.
        FeedPickerMenu(
            mode: feedService.feedMode,
            connectionStatus: feedService.connectionStatus,
            isCompactWidth: isCompactWidth,
            modes: menuModes,
            onSelect: { feedService.switchMode($0) },
            onEdit: { showingFeedMenuEditor = true },
            onDashboard: { showingDashboard = true }
        )
        .equatable()
        // The Feeds tutorial points here, and starts here the first time
        // the feed shows (after Fill your vault; see TutorialProgress).
        // Re-checked when a status is saved, so an account whose Fill your
        // vault is marked done after its follow list loads gets Feeds now.
        .tutorialAnchor(TutorialContent.feedPicker)
        .task(id: "\(configService.activeAccountHexPubkey).\(tutorialCenter.revision)") {
            tutorialCenter.startIfEligible(.feeds, account: configService.activeAccountHexPubkey)
        }
    }
    #endif

    /// The floating "New Posts" button is up: unloaded posts, and either
    /// auto-load is off, the user has scrolled away from the top, or a
    /// tapped post is open (which holds auto-load back). Never
    /// when it's switched off in Appearance settings. It is an ambient pill
    /// (`docs/pills.md`): `.ambientPill()` hides it while the lane is busy.
    var showsNewPostsButton: Bool {
        configService.config.showNewPostsPill
            && feedService.visiblePendingCount > 0 && (!configService.config.autoLoadNewPosts || !isAtTop || expandedNoteId != nil)
    }

    #if os(iOS)
    /// Folded, the "New Posts" button becomes a small arrow-and-count pill
    /// centred in the top bar's row, between its two circles.
    @ViewBuilder
    var foldedNewPostsPill: some View {
        if isCompactWidth && navigationPath.isEmpty && showsNewPostsButton {
            ChromeFold(inverted: true) {
                newPostsButton(compact: true) {
                    NotificationCenter.default.post(name: NSNotification.Name("ScrollToTop"), object: nil)
                }
            }
            // Centred on the bar's top edge, then down to its circles' centre.
            .frame(height: 0)
            .offset(y: 22)
            .ambientPill()
            .transition(.opacity)
        }
    }
    #endif

    func scrollToTopAfterLoad(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(Motion.scrollJump) {
                proxy.scrollTo("top", anchor: .top)
            }
        }
    }

    /// The "New Posts" button, full size or as the small folded pill.
    /// Loads the waiting posts, then `scrollToTop`.
    func newPostsButton(compact: Bool, scrollToTop: @escaping () -> Void) -> some View {
        Button(action: {
            feedService.applyPendingNotes()
            scrollToTop()
        }) {
            HStack(spacing: compact ? 4 : 8) {
                Image(systemName: "arrow.up")
                    .font(.appSystem(size: compact ? 11 : 12, weight: .bold))
                Text(compact ? (feedService.visiblePendingCount > 99 ? "99+" : "\(feedService.visiblePendingCount)")
                             : "\(feedService.visiblePendingCount) New Posts")
                    .font(.appSystem(size: compact ? 12 : 13, weight: .bold))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(feedService.visiblePendingCount)))
            }
            .padding(.vertical, compact ? 5 : 10)
            .padding(.horizontal, compact ? 10 : 20)
            .background(
                Capsule()
                    .fill(Color.havenPurple)
                    .shadow(color: Color.black.opacity(0.4), radius: compact ? 4 : 8, x: 0, y: compact ? 2 : 4)
            )
            .foregroundColor(.white)
            // The small pill's tap target, without growing the pill.
            .padding(compact ? 8 : 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(feedService.visiblePendingCount) new posts, tap to load")
        .animation(Motion.fade, value: feedService.visiblePendingCount)
    }

    /// Cycles expanded → condensed → threaded. Shared by the full trailing
    /// row and the collapsed top bar, which keeps only this button.
    var layoutModeButton: some View {
        IconFilterButton(
            icon: layoutModeForCurrentFeed.symbolName,
            tooltip: layoutModeForCurrentFeed.displayName,
            isSelected: layoutModeForCurrentFeed != .expanded,
            color: .havenPurple
        ) {
            cycleLayoutModeForCurrentFeed()
        }
    }

    // MARK: - Feed Trailing Toolbar (inline vs. compact menu)

    @ViewBuilder
    var feedTrailingToolbarInline: some View {
        HStack(spacing: 4) {
            if currentFeedHasLayouts {
                layoutModeButton

                Divider()
                    .frame(height: 20)
                    .padding(.horizontal, 4)
            }

            if feedService.feedMode == .reels {
                IconFilterButton(icon: reelsService.scope == .following ? "person.2.fill" : "person.2", tooltip: "Following", isSelected: reelsService.scope == .following, color: .havenPurple) {
                    reelsService.setScope(.following)
                }
                IconFilterButton(icon: "globe", tooltip: "Global", isSelected: reelsService.scope == .global, color: .havenPurple) {
                    reelsService.setScope(.global)
                }
                if reelsService.scope == .global {
                    trustScopeButton
                }
            } else if feedService.feedMode == .media {
                IconFilterButton(icon: feedService.mediaFeedMode == .following ? "person.2.fill" : "person.2", tooltip: "Following", isSelected: feedService.mediaFeedMode == .following, color: .havenPurple) {
                    feedService.mediaFeedMode = .following
                    feedService.refresh()
                }
                IconFilterButton(icon: "globe", tooltip: "Global", isSelected: feedService.mediaFeedMode == .global, color: .havenPurple) {
                    setMediaGlobal()
                }
                if feedService.mediaFeedMode == .global {
                    trustScopeButton
                }
            } else if feedService.feedMode == .recipes {
                IconFilterButton(icon: recipeService.scope == .following ? "person.2.fill" : "person.2", tooltip: "Following", isSelected: recipeService.scope == .following, color: .havenPurple) {
                    recipeService.setScope(.following)
                }
                IconFilterButton(icon: "globe", tooltip: "Global", isSelected: recipeService.scope == .global, color: .havenPurple) {
                    recipeService.setScope(.global)
                }
                if recipeService.scope == .global {
                    trustScopeButton
                }
            } else if feedService.feedMode == .articles {
                // Same Following / Global pair as Media. Articles has no
                // auto-load, reposts or replies buttons, so the pair fits.
                IconFilterButton(icon: feedService.articlesFeedMode == .following ? "person.2.fill" : "person.2", tooltip: "Following", isSelected: feedService.articlesFeedMode == .following, color: .havenPurple) {
                    setArticlesFeedMode(.following)
                }
                IconFilterButton(icon: "globe", tooltip: "Global", isSelected: feedService.articlesFeedMode == .global, color: .havenPurple) {
                    setArticlesFeedMode(.global)
                }
                if feedService.articlesFeedMode == .global {
                    trustScopeButton
                }
            } else if feedService.feedMode == .polls {
                // One scope toggle, not a Following / Global pair: with the
                // shield, status and auto-load buttons a pair is too wide for
                // an iPhone, and the whole row falls back to the Filter menu.
                IconFilterButton(icon: feedService.pollsFeedMode == .following ? "person.2.fill" : "globe", tooltip: feedService.pollsFeedMode == .following ? "Following" : "Global", isSelected: true, color: .havenPurple) {
                    PollsFeed.setScope(feedService.pollsFeedMode == .following ? .global : .following)
                }
                if feedService.pollsFeedMode == .global {
                    trustScopeButton
                }
                PollStatusFilterMenu(selected: feedService.pollStatusFilter, color: .havenPurple)
                IconFilterButton(icon: configService.config.autoLoadNewPosts ? "bolt.circle.fill" : "bolt.circle", tooltip: "Auto-load", isSelected: configService.config.autoLoadNewPosts, color: .havenPurple) {
                    configService.config.autoLoadNewPosts.toggle()
                    configService.save()
                }
            } else if feedService.feedMode == .marketplace {
                // Global is the default, and like every Global view it starts
                // on the Web of Trust; only the shield's Everyone warns.
                IconFilterButton(icon: marketplaceService.scope == .following ? "person.2.fill" : "person.2", tooltip: "Following", isSelected: marketplaceService.scope == .following, color: .havenPurple) {
                    marketplaceService.setScope(.following)
                }
                IconFilterButton(icon: "globe", tooltip: "Global", isSelected: marketplaceService.scope == .global, color: .havenPurple) {
                    marketplaceService.setScope(.global)
                }
                if marketplaceService.scope == .global {
                    trustScopeButton
                }
            } else if feedService.feedMode == .hashtags {
                // Follows and network always show here; the shield picks
                // network or everyone, as on the hashtag sheet.
                trustScopeButton
            } else if feedService.feedMode == .music {
                MusicToolbarButtons()
            } else if feedService.feedMode == .live {
                IconFilterButton(icon: liveService.scope == .following ? "person.2.fill" : "person.2", tooltip: "Following", isSelected: liveService.scope == .following, color: .havenPurple) {
                    liveService.setScope(.following)
                }
                IconFilterButton(icon: "globe", tooltip: "Global", isSelected: liveService.scope == .global, color: .havenPurple) {
                    liveService.setScope(.global)
                }
                if liveService.scope == .global {
                    trustScopeButton
                }
            } else if feedService.feedMode == .popular {
                PopularAudienceMenu(selected: feedService.popularFilter, color: .havenPurple, onSelect: setPopularFilter)
                IconFilterButton(icon: feedService.showPopularEngagement ? "flame.fill" : "flame", tooltip: "Ranks", isSelected: feedService.showPopularEngagement, color: .havenPurple) {
                    feedService.showPopularEngagement.toggle()
                }
            } else {
                if feedService.feedMode == .global {
                    // One button for who Global shows, so the pill keeps its
                    // width: the shield is your Web of Trust, the crossed-out
                    // shield is everyone (behind a warning).
                    trustScopeButton
                    LanguageFilterMenu(selected: configService.config.globalFeedLanguages, color: .havenPurple) { codes in
                        configService.config.globalFeedLanguages = codes
                        configService.save()
                        feedService.recomputeFilteredNotes()
                    }
                }
                IconFilterButton(icon: configService.config.autoLoadNewPosts ? "bolt.circle.fill" : "bolt.circle", tooltip: "Auto-load", isSelected: configService.config.autoLoadNewPosts, color: .havenPurple) {
                    configService.config.autoLoadNewPosts.toggle()
                    configService.save()
                }
                IconFilterButton(icon: "arrow.2.squarepath", tooltip: "Reposts", isSelected: configService.config.showReposts, color: .havenPurple) {
                    configService.config.showReposts.toggle()
                    configService.save()
                    feedService.recomputeFilteredNotes()
                }
                // Global never shows replies (FeedFilterEngine), so the
                // toggle would do nothing there.
                if feedService.feedMode != .global {
                    IconFilterButton(icon: configService.config.showReplies ? "message.fill" : "message", tooltip: "Replies", isSelected: configService.config.showReplies, color: .havenPurple) {
                        configService.config.showReplies.toggle()
                        configService.save()
                        feedService.recomputeFilteredNotes()
                    }
                }
            }
        }
    }
}

// MARK: - Toolbar note

/// Every setting the feed's top-right toolbar shows, for the current feed.
/// A change to one of them is a toolbar tap (or a pick from its menus), and
/// leaves a note under the toolbar saying what the button does and what it
/// is set to now: "Global · Web of Trust on".
struct FeedToolbarState: Equatable {
    var account: String
    var mode: FeedMode
    /// Following / Global for the feeds that have the pair; nil elsewhere.
    var followingScope: Bool?
    var everyone: Bool
    var languages: [String]
    var autoLoad: Bool
    var reposts: Bool
    var replies: Bool
    var layout: FeedLayoutMode
    var pollStatus: PollStatusFilter
    var popular: PopularFilter
    var engagement: Bool

    /// The note for what changed from `old`, if a toolbar setting did.
    /// Nothing when the feed or account switched: those are not toolbar taps,
    /// and every setting can differ between feeds.
    func note(changedFrom old: FeedToolbarState) -> FilterNote? {
        guard account == old.account, mode == old.mode else { return nil }
        let feed = mode.displayName
        if followingScope != old.followingScope, let following = followingScope {
            return following
                ? FilterNote(icon: "person.2.fill", title: feed, setting: "Following")
                : FilterNote(icon: "globe", title: feed, setting: "Global")
        }
        if everyone != old.everyone {
            return FilterNote(icon: everyone ? "shield.slash.fill" : "checkmark.shield.fill", title: feed, setting: everyone ? "Everyone" : "Web of Trust on")
        }
        if languages != old.languages {
            return FilterNote(icon: languages.isEmpty ? "character.bubble" : "character.bubble.fill",
                              title: "Languages", setting: Self.languageSetting(languages))
        }
        if autoLoad != old.autoLoad {
            return autoLoad
                ? FilterNote(icon: "bolt.circle.fill", title: "Auto-load", setting: "on")
                : .off("Auto-load", icon: "bolt.circle.fill")
        }
        if reposts != old.reposts {
            return Self.shownOrHidden("Reposts", icon: "arrow.2.squarepath", shown: reposts)
        }
        if replies != old.replies {
            return Self.shownOrHidden("Replies", icon: "message.fill", shown: replies)
        }
        if layout != old.layout {
            return FilterNote(icon: layout.symbolName, title: "Layout", setting: layout.shortName)
        }
        if pollStatus != old.pollStatus {
            return FilterNote(icon: pollStatus.symbolName, title: "Polls", setting: pollStatus == .all ? "Open and closed" : "\(pollStatus.rawValue) only")
        }
        if popular != old.popular {
            return FilterNote(icon: popular.symbolName, title: "Popular", setting: popular.menuTitle)
        }
        if engagement != old.engagement {
            return Self.shownOrHidden("Ranks", icon: "flame.fill", shown: engagement)
        }
        return nil
    }

    /// The picked languages, at most two by name: "English, Spanish +2".
    /// Multi-select would otherwise push the setting past the pill's width.
    static func languageSetting(_ codes: [String]) -> String {
        guard codes.count > 2 else { return LanguageFilterMenuItems.summary(codes) }
        return LanguageFilterMenuItems.summary(Array(codes.prefix(2))) + " +\(codes.count - 2)"
    }

    /// A show/hide toggle: "Reposts · shown", or "Reposts · hidden" with
    /// the button's own icon dimmed, as `FilterNote.off` does.
    private static func shownOrHidden(_ title: String, icon: String, shown: Bool) -> FilterNote {
        shown
            ? FilterNote(icon: icon, title: title, setting: "shown")
            : FilterNote(icon: icon, title: title, setting: "hidden", dimmed: true)
    }
}

extension FeedView {
    var toolbarState: FeedToolbarState {
        FeedToolbarState(
            account: configService.activeAccountHexPubkey,
            mode: feedService.feedMode,
            followingScope: followingScope,
            everyone: configService.config.globalShowsEveryone,
            languages: configService.config.globalFeedLanguages,
            autoLoad: configService.config.autoLoadNewPosts,
            reposts: configService.config.showReposts,
            replies: configService.config.showReplies,
            layout: layoutModeForCurrentFeed,
            pollStatus: feedService.pollStatusFilter,
            popular: feedService.popularFilter,
            engagement: feedService.showPopularEngagement
        )
    }

    private var followingScope: Bool? {
        switch feedService.feedMode {
        case .reels: return reelsService.scope == .following
        case .media: return feedService.mediaFeedMode == .following
        case .recipes: return recipeService.scope == .following
        case .articles: return feedService.articlesFeedMode == .following
        case .polls: return feedService.pollsFeedMode == .following
        case .marketplace: return marketplaceService.scope == .following
        case .live: return liveService.scope == .following
        default: return nil
        }
    }
}

/// Shows the toolbar's note for Music, whose buttons are all menus on
/// `MusicFeedState`. Its own view so music updates don't re-render the feed.
struct MusicToolbarNoteObserver: View {
    @ObservedObject private var feed = MusicFeedState.shared
    let model: FilterNoteModel

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: feed.scope) { _, _ in model.show(note) }
            .onChange(of: feed.trendingWindow) { _, _ in model.show(note) }
    }

    private var note: FilterNote {
        switch feed.scope {
        case .trending: return FilterNote(icon: "flame.fill", title: "Music", setting: "Trending \(feed.trendingWindow.title.lowercased())")
        case .artist(let artist): return FilterNote(icon: "person.crop.circle.fill", title: "Music", setting: artist.name)
        case .following: return FilterNote(icon: "person.2.fill", title: "Music", setting: "Artists you follow")
        }
    }
}

private extension FeedLayoutMode {
    /// "Threaded", for the toolbar note; `displayName` adds " View".
    var shortName: String {
        switch self {
        case .expanded: return "Expanded"
        case .condensed: return "Compact"
        case .threaded: return "Threaded"
        }
    }
}
