import SwiftUI

extension FeedView {
    #if os(macOS)
    var macFeedHeader: some View {
        HStack(spacing: 12) {
            // Feed mode picker
            Menu {
                ForEach(menuModes, id: \.self) { mode in
                    Button(action: { feedService.switchMode(mode) }) {
                        let displayName = mode == .discovery ? "Discover" : mode.rawValue
                        if feedService.feedMode == mode {
                            Label(displayName, systemImage: "checkmark")
                        } else {
                            Text(displayName)
                        }
                    }
                }
                Divider()
                Button("Edit Feeds…") { showingFeedMenuEditor = true }
            } label: {
                HStack(spacing: 4) {
                    let displayName = feedService.feedMode == .discovery ? "Discover" : feedService.feedMode.rawValue
                    Text(displayName)
                        .font(.appSystem(size: 13, weight: .semibold))
                    Image(systemName: "chevron.down")
                        .font(.appSystem(size: 9, weight: .bold))
                }
                .foregroundColor(.primary)
                .contentShape(Rectangle())
            }
            // .borderlessButton flattens the label's font and colour on the
            // Mac; this header is macOS-only. The label draws its own chevron.
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .help("Switch feed")
            .fixedSize()

            Spacer()

            if feedService.feedMode == .reels {
                Button(action: { reelsService.setScope(.following) }) {
                    Image(systemName: reelsService.scope == .following ? "person.2.fill" : "person.2")
                        .font(.appSystem(size: 15, weight: .semibold))
                        .foregroundColor(reelsService.scope == .following ? Color.havenPurple : .secondary)
                }
                .buttonStyle(.plain)
                .help("Videos from people you follow")

                Button(action: { reelsService.setScope(.global) }) {
                    Image(systemName: "globe")
                        .font(.appSystem(size: 15, weight: .semibold))
                        .foregroundColor(reelsService.scope == .global ? Color.havenPurple : .secondary)
                }
                .buttonStyle(.plain)
                .help("Global videos: your Web of Trust, or everyone with the shield off")

                if reelsService.scope == .global {
                    trustScopeButton
                }
            } else if feedService.feedMode == .media {
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
                    setMediaGlobal()
                }) {
                    Image(systemName: "globe")
                        .font(.appSystem(size: 15, weight: .semibold))
                        .foregroundColor(feedService.mediaFeedMode == .global ? Color.havenPurple : .secondary)
                }
                .buttonStyle(.plain)
                .help(String(localized: "feed.help.globalMedia"))

                if feedService.mediaFeedMode == .global {
                    trustScopeButton
                }
            } else if feedService.feedMode == .articles {
                Button(action: { setArticlesFeedMode(.following) }) {
                    Image(systemName: feedService.articlesFeedMode == .following ? "person.2.fill" : "person.2")
                        .font(.appSystem(size: 15, weight: .semibold))
                        .foregroundColor(feedService.articlesFeedMode == .following ? Color.havenPurple : .secondary)
                }
                .buttonStyle(.plain)
                .help("Articles from people you follow")

                Button(action: { setArticlesFeedMode(.global) }) {
                    Image(systemName: "globe")
                        .font(.appSystem(size: 15, weight: .semibold))
                        .foregroundColor(feedService.articlesFeedMode == .global ? Color.havenPurple : .secondary)
                }
                .buttonStyle(.plain)
                .help("Global articles: your Web of Trust, or everyone with the shield off")

                if feedService.articlesFeedMode == .global {
                    trustScopeButton
                }
            } else if feedService.feedMode == .polls {
                Button(action: { PollsFeed.setScope(.following) }) {
                    Image(systemName: feedService.pollsFeedMode == .following ? "person.2.fill" : "person.2")
                        .font(.appSystem(size: 15, weight: .semibold))
                        .foregroundColor(feedService.pollsFeedMode == .following ? Color.havenPurple : .secondary)
                }
                .buttonStyle(.plain)
                .help("Polls from people you follow")

                Button(action: { PollsFeed.setScope(.global) }) {
                    Image(systemName: "globe")
                        .font(.appSystem(size: 15, weight: .semibold))
                        .foregroundColor(feedService.pollsFeedMode == .global ? Color.havenPurple : .secondary)
                }
                .buttonStyle(.plain)
                .help("Global polls: your Web of Trust, or everyone with the shield off")

                if feedService.pollsFeedMode == .global {
                    trustScopeButton
                }
                PollStatusFilterMenu(selected: feedService.pollStatusFilter, color: .havenPurple)
                Button(action: { configService.config.autoLoadNewPosts.toggle(); configService.save() }) {
                    Image(systemName: configService.config.autoLoadNewPosts ? "bolt.circle.fill" : "bolt.circle")
                        .font(.appSystem(size: 15, weight: .semibold))
                        .foregroundColor(configService.config.autoLoadNewPosts ? Color.havenPurple : .secondary)
                }
                .buttonStyle(.plain)
                .help(configService.config.autoLoadNewPosts ? String(localized: "feed.help.autoLoadOn") : String(localized: "feed.help.autoLoadOff"))
            } else if feedService.feedMode == .recipes {
                Button(action: { recipeService.setScope(.following) }) {
                    Image(systemName: recipeService.scope == .following ? "person.2.fill" : "person.2")
                        .font(.appSystem(size: 15, weight: .semibold))
                        .foregroundColor(recipeService.scope == .following ? Color.havenPurple : .secondary)
                }
                .buttonStyle(.plain)
                .help("Recipes from people you follow")

                Button(action: { recipeService.setScope(.global) }) {
                    Image(systemName: "globe")
                        .font(.appSystem(size: 15, weight: .semibold))
                        .foregroundColor(recipeService.scope == .global ? Color.havenPurple : .secondary)
                }
                .buttonStyle(.plain)
                .help("Global recipes: your Web of Trust, or everyone with the shield off")

                if recipeService.scope == .global {
                    trustScopeButton
                }
            } else if feedService.feedMode == .marketplace {
                Button(action: { marketplaceService.setScope(.following) }) {
                    Image(systemName: marketplaceService.scope == .following ? "person.2.fill" : "person.2")
                        .font(.appSystem(size: 15, weight: .semibold))
                        .foregroundColor(marketplaceService.scope == .following ? Color.havenPurple : .secondary)
                }
                .buttonStyle(.plain)
                .help("Listings from people you follow")

                Button(action: { marketplaceService.setScope(.global) }) {
                    Image(systemName: "globe")
                        .font(.appSystem(size: 15, weight: .semibold))
                        .foregroundColor(marketplaceService.scope == .global ? Color.havenPurple : .secondary)
                }
                .buttonStyle(.plain)
                .help("Global listings: your Web of Trust, or everyone with the shield off")

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
                Button(action: { liveService.setScope(.following) }) {
                    Image(systemName: liveService.scope == .following ? "person.2.fill" : "person.2")
                        .font(.appSystem(size: 15, weight: .semibold))
                        .foregroundColor(liveService.scope == .following ? Color.havenPurple : .secondary)
                }
                .buttonStyle(.plain)
                .help("Streams from people you follow")

                Button(action: { liveService.setScope(.global) }) {
                    Image(systemName: "globe")
                        .font(.appSystem(size: 15, weight: .semibold))
                        .foregroundColor(liveService.scope == .global ? Color.havenPurple : .secondary)
                }
                .buttonStyle(.plain)
                .help("Global streams: your Web of Trust, or everyone with the shield off")

                if liveService.scope == .global {
                    trustScopeButton
                }
            } else if feedService.feedMode == .popular {
                PopularAudienceMenu(selected: feedService.popularFilter, color: .havenPurple, onSelect: setPopularFilter)

                // Rank line above each post
                Button(action: { feedService.showPopularEngagement.toggle() }) {
                    Image(systemName: feedService.showPopularEngagement ? "flame.fill" : "flame")
                        .font(.appSystem(size: 15, weight: .semibold))
                        .foregroundColor(feedService.showPopularEngagement ? Color.havenPurple : .secondary)
                }
                .buttonStyle(.plain)
                .help(feedService.showPopularEngagement ? "Hide ranks" : "Show ranks")
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

                // Replies toggle (Global never shows replies)
                if feedService.feedMode != .global {
                    Button(action: { configService.config.showReplies.toggle(); configService.save(); feedService.recomputeFilteredNotes() }) {
                        Image(systemName: configService.config.showReplies ? "message.fill" : "message")
                            .font(.appSystem(size: 15, weight: .semibold))
                            .foregroundColor(configService.config.showReplies ? Color.havenPurple : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(configService.config.showReplies ? String(localized: "feed.help.hideReplies") : String(localized: "feed.help.showReplies"))
                }

                if feedService.feedMode == .global {
                    trustScopeButton

                    LanguageFilterMenu(selected: configService.config.globalFeedLanguages, color: .havenPurple) { codes in
                        configService.config.globalFeedLanguages = codes
                        configService.save()
                        feedService.recomputeFilteredNotes()
                    }
                }

                // Divider to separate the layout cycle
                Divider()
                    .frame(height: 20)
                    .padding(.horizontal, 8)

                // Layout cycle: expanded -> condensed -> threaded
                Button(action: {
                    cycleLayoutModeForCurrentFeed()
                }) {
                    Image(systemName: layoutModeForCurrentFeed.symbolName)
                        .font(.appSystem(size: 15, weight: .semibold))
                        .foregroundColor(layoutModeForCurrentFeed == .expanded ? .secondary : Color.havenPurple)
                }
                .buttonStyle(.plain)
                .help("\(layoutModeForCurrentFeed.displayName) — click for \(layoutModeForCurrentFeed.nextDisplayName(supportsThreading: currentFeedSupportsThreading))")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.platformSecondaryGroupedBackground)
    }
    #endif
}
