import SwiftUI

#if os(iOS)
extension FeedView {
    /// iPad two-pane only: the feed's controls sit over the feed column they
    /// act on, not in the bar that spans both panes (where they landed over
    /// the reading pane, far from the list). The picker is on the left; the
    /// layout button and one Filter button are on the right. Every filter
    /// setting is a labelled row inside Filter, and the badge counts the ones
    /// not at their default, so the header keeps one width on every feed.
    var feedColumnHeader: some View {
        HStack(spacing: 8) {
            feedLeadingToolbar
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                if currentFeedHasLayouts {
                    layoutModeButton
                }
                feedFilterButton
            }
            .tutorialAnchor(TutorialContent.feedToolbar)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.platformWindowBackground)
        .overlay(alignment: .bottom) { Divider() }
    }

    var feedFilterBadge: FeedFilterBadge {
        let config = configService.config
        var badge = FeedFilterBadge()
        let scopeFollowing: Bool? = {
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
        }()
        badge.followingScope = scopeFollowing
        if feedService.feedMode == .marketplace {
            badge.defaultFollowingScope = !MarketScopeGate.opensOnGlobal
        }
        // The shield only applies once a feed is on Global (Hashtags always).
        if scopeFollowing == false || feedService.feedMode == .global || feedService.feedMode == .hashtags {
            badge.everyone = config.globalShowsEveryone
        }
        switch feedService.feedMode {
        case .polls:
            badge.pollStatusNarrowed = feedService.pollStatusFilter != .all
            badge.autoLoad = config.autoLoadNewPosts
        case .popular:
            badge.popularNarrowed = feedService.popularFilter != .all
            badge.ranks = feedService.showPopularEngagement
        case .following, .discovery, .global:
            badge.autoLoad = config.autoLoadNewPosts
            badge.reposts = config.showReposts
            // Global never shows replies (FeedFilterEngine).
            if feedService.feedMode != .global { badge.replies = config.showReplies }
            if feedService.feedMode == .global { badge.languageCount = config.globalFeedLanguages.count }
        default:
            break
        }
        return badge
    }

    private var feedFilterButton: some View {
        let count = feedFilterBadge.count
        return Menu {
            feedFilterMenuItems
        } label: {
            Image(systemName: count > 0
                  ? "line.3.horizontal.decrease.circle.fill"
                  : "line.3.horizontal.decrease.circle")
                .font(.appSystem(size: 20, weight: .regular))
                .foregroundColor(.havenPurple)
                .frame(width: 36, height: 36)
                .overlay(alignment: .topTrailing) {
                    if count > 0 {
                        Text("\(count)")
                            .font(.appSystem(size: 11, weight: .bold))
                            .monospacedDigit()
                            .foregroundColor(.white)
                            .frame(minWidth: 16, minHeight: 16)
                            .padding(.horizontal, count > 9 ? 3 : 0)
                            .background(Capsule().fill(Color.havenPurple))
                            .overlay(Capsule().strokeBorder(Color.platformWindowBackground, lineWidth: 1.5))
                            .offset(x: 2, y: -1)
                    }
                }
                .contentShape(Rectangle())
        }
        .accessibilityLabel(feedFilterBadge.accessibilityLabel)
    }

    /// A Following / Global choice as one labelled, checkmarked pair.
    private func scopePicker(following: Bool, set: @escaping (Bool) -> Void) -> some View {
        Picker("Show posts from", selection: Binding(get: { following }, set: set)) {
            Label("Following", systemImage: "person.2").tag(true)
            Label("Global", systemImage: "globe").tag(false)
        }
        .pickerStyle(.inline)
    }

    private func configToggle(_ title: String, icon: String, _ key: WritableKeyPath<HavenConfig, Bool>, refilter: Bool) -> some View {
        Toggle(isOn: Binding(
            get: { configService.config[keyPath: key] },
            set: { value in
                configService.config[keyPath: key] = value
                configService.save()
                if refilter { feedService.recomputeFilteredNotes() }
            }
        )) {
            Label(title, systemImage: icon)
        }
    }

    private var autoLoadToggle: some View {
        configToggle("Auto-load new posts", icon: "bolt.circle", \.autoLoadNewPosts, refilter: false)
    }

    /// Web of Trust or Everyone, in the same checkmark style as the rest of
    /// the menu. Everyone still goes through its warning.
    private var trustSection: some View {
        Picker("Who", selection: Binding(
            get: { configService.config.globalShowsEveryone },
            set: { everyone in
                if everyone {
                    if !configService.config.globalShowsEveryone { requestEveryone() }
                } else {
                    setGlobalShowsEveryone(false)
                }
            }
        )) {
            Label("Web of Trust", systemImage: "checkmark.shield").tag(false)
            Label("Everyone", systemImage: "shield.slash").tag(true)
        }
        .pickerStyle(.inline)
    }

    @ViewBuilder
    var feedFilterMenuItems: some View {
        switch feedService.feedMode {
        case .reels:
            scopePicker(following: reelsService.scope == .following) { reelsService.setScope($0 ? .following : .global) }
            if reelsService.scope == .global { trustSection }
        case .media:
            scopePicker(following: feedService.mediaFeedMode == .following) { following in
                if following {
                    feedService.mediaFeedMode = .following
                    feedService.refresh()
                } else {
                    setMediaGlobal()
                }
            }
            if feedService.mediaFeedMode == .global { trustSection }
        case .recipes:
            scopePicker(following: recipeService.scope == .following) { recipeService.setScope($0 ? .following : .global) }
            if recipeService.scope == .global { trustSection }
        case .articles:
            scopePicker(following: feedService.articlesFeedMode == .following) { setArticlesFeedMode($0 ? .following : .global) }
            if feedService.articlesFeedMode == .global { trustSection }
        case .polls:
            scopePicker(following: feedService.pollsFeedMode == .following) { PollsFeed.setScope($0 ? .following : .global) }
            if feedService.pollsFeedMode == .global { trustSection }
            Picker("Polls", selection: Binding(get: { feedService.pollStatusFilter },
                                               set: { PollsFeed.setStatus($0) })) {
                ForEach(PollStatusFilter.allCases, id: \.self) { filter in
                    Label(filter.rawValue, systemImage: filter.symbolName).tag(filter)
                }
            }
            .pickerStyle(.inline)
            autoLoadToggle
        case .marketplace:
            scopePicker(following: marketplaceService.scope == .following) { marketplaceService.setScope($0 ? .following : .global) }
            if marketplaceService.scope == .global { trustSection }
        case .hashtags:
            trustSection
        case .music:
            MusicToolbarMenuItems()
        case .live:
            scopePicker(following: liveService.scope == .following) { liveService.setScope($0 ? .following : .global) }
            if liveService.scope == .global { trustSection }
        case .popular:
            PopularAudienceMenuItems(selected: feedService.popularFilter, onSelect: setPopularFilter)
            Toggle(isOn: Binding(get: { feedService.showPopularEngagement },
                                 set: { feedService.showPopularEngagement = $0 })) {
                Label("Show ranks", systemImage: "flame")
            }
        case .following, .discovery, .global:
            if feedService.feedMode == .global {
                trustSection
                Menu {
                    LanguageFilterMenuItems(selected: configService.config.globalFeedLanguages) { codes in
                        configService.config.globalFeedLanguages = codes
                        configService.save()
                        feedService.recomputeFilteredNotes()
                    }
                } label: {
                    Label(configService.config.globalFeedLanguages.isEmpty
                          ? "Languages: All"
                          : "Languages: \(FeedToolbarState.languageSetting(configService.config.globalFeedLanguages))",
                          systemImage: "character.bubble")
                }
            }
            Section {
                autoLoadToggle
                configToggle("Show reposts", icon: "arrow.2.squarepath", \.showReposts, refilter: true)
                if feedService.feedMode != .global {
                    configToggle("Show replies", icon: "message", \.showReplies, refilter: true)
                }
            }
        }
    }
}
#endif
