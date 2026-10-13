import SwiftUI

extension FeedView {
    @ViewBuilder
    var feedTrailingToolbarMenu: some View {
        Menu {
            // One entry per layout rather than a cycle — a menu can show where
            // each choice leads, which a single cycling button cannot.
            if currentFeedHasLayouts {
                ForEach(FeedLayoutMode.allCases, id: \.self) { mode in
                    if mode != .threaded || currentFeedSupportsThreading {
                        Button {
                            setLayoutModeForCurrentFeed(mode)
                        } label: {
                            Label(mode.displayName, systemImage: layoutModeForCurrentFeed == mode ? "checkmark" : mode.symbolName)
                        }
                    }
                }

                Divider()
            }

            if feedService.feedMode == .reels {
                Button { reelsService.setScope(.following) } label: {
                    Label("Following", systemImage: reelsService.scope == .following ? "checkmark" : "person.2")
                }
                Button { reelsService.setScope(.global) } label: {
                    Label("Global", systemImage: reelsService.scope == .following ? "globe" : "checkmark")
                }
                if reelsService.scope == .global {
                    Divider()
                    trustScopeMenuItems
                }
            } else if feedService.feedMode == .media {
                Button {
                    feedService.mediaFeedMode = .following
                    feedService.refresh()
                } label: {
                    Label("Following", systemImage: feedService.mediaFeedMode == .following ? "checkmark" : "person.2")
                }
                Button { setMediaGlobal() } label: {
                    Label("Global", systemImage: feedService.mediaFeedMode == .following ? "globe" : "checkmark")
                }
                if feedService.mediaFeedMode == .global {
                    Divider()
                    trustScopeMenuItems
                }
            } else if feedService.feedMode == .recipes {
                Button { recipeService.setScope(.following) } label: {
                    Label("Following", systemImage: recipeService.scope == .following ? "checkmark" : "person.2")
                }
                Button { recipeService.setScope(.global) } label: {
                    Label("Global", systemImage: recipeService.scope == .following ? "globe" : "checkmark")
                }
                if recipeService.scope == .global {
                    Divider()
                    trustScopeMenuItems
                }
            } else if feedService.feedMode == .articles {
                Button { setArticlesFeedMode(.following) } label: {
                    Label("Following", systemImage: feedService.articlesFeedMode == .following ? "checkmark" : "person.2")
                }
                Button { setArticlesFeedMode(.global) } label: {
                    Label("Global", systemImage: feedService.articlesFeedMode == .following ? "globe" : "checkmark")
                }
                if feedService.articlesFeedMode == .global {
                    Divider()
                    trustScopeMenuItems
                }
            } else if feedService.feedMode == .polls {
                Button { PollsFeed.setScope(.following) } label: {
                    Label("Following", systemImage: feedService.pollsFeedMode == .following ? "checkmark" : "person.2")
                }
                Button { PollsFeed.setScope(.global) } label: {
                    Label("Global", systemImage: feedService.pollsFeedMode == .following ? "globe" : "checkmark")
                }
                if feedService.pollsFeedMode == .global {
                    Divider()
                    trustScopeMenuItems
                }
                Divider()
                PollStatusFilterMenuItems(selected: feedService.pollStatusFilter)
                Divider()
                Button {
                    configService.config.autoLoadNewPosts.toggle()
                    configService.save()
                } label: {
                    Label("Auto-load", systemImage: configService.config.autoLoadNewPosts ? "bolt.circle.fill" : "bolt.circle")
                }
            } else if feedService.feedMode == .marketplace {
                Button { marketplaceService.setScope(.following) } label: {
                    Label("Following", systemImage: marketplaceService.scope == .following ? "checkmark" : "person.2")
                }
                Button { marketplaceService.setScope(.global) } label: {
                    Label("Global", systemImage: marketplaceService.scope == .global ? "checkmark" : "globe")
                }
                if marketplaceService.scope == .global {
                    Divider()
                    trustScopeMenuItems
                }
            } else if feedService.feedMode == .hashtags {
                trustScopeMenuItems
            } else if feedService.feedMode == .music {
                MusicToolbarMenuItems()
            } else if feedService.feedMode == .live {
                Button { liveService.setScope(.following) } label: {
                    Label("Following", systemImage: liveService.scope == .following ? "checkmark" : "person.2")
                }
                Button { liveService.setScope(.global) } label: {
                    Label("Global", systemImage: liveService.scope == .following ? "globe" : "checkmark")
                }
                if liveService.scope == .global {
                    Divider()
                    trustScopeMenuItems
                }
            } else if feedService.feedMode == .popular {
                PopularAudienceMenuItems(selected: feedService.popularFilter, onSelect: setPopularFilter)
                Divider()
                Button {
                    feedService.showPopularEngagement.toggle()
                } label: {
                    Label(feedService.showPopularEngagement ? "Hide ranks" : "Show ranks", systemImage: "flame")
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
                // Same rule as the inline toolbar: Global has no replies.
                if feedService.feedMode != .global {
                    Button {
                        configService.config.showReplies.toggle()
                        configService.save()
                        feedService.recomputeFilteredNotes()
                    } label: {
                        Label("Replies", systemImage: configService.config.showReplies ? "message.fill" : "message")
                    }
                }
                if feedService.feedMode == .global {
                    trustScopeMenuItems
                    Menu {
                        LanguageFilterMenuItems(selected: configService.config.globalFeedLanguages) { codes in
                            configService.config.globalFeedLanguages = codes
                            configService.save()
                            feedService.recomputeFilteredNotes()
                        }
                    } label: {
                        Label("Languages", systemImage: "character.bubble")
                    }
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
}
