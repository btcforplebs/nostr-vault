import SwiftUI

extension FeedView {
    /// The feed, with the music mini player docked at the bottom where
    /// there's no iPhone tab bar to carry it (iPad, Mac).
    var rootContent: some View {
        rootContentBase.modifier(MiniPlayerInset())
    }

    private var rootContentBase: some View {
        ZStack {
            // Match the platform theme background
            Color.platformWindowBackground.ignoresSafeArea()

            Group {
                // Only show the full-screen contact-loading spinner when there
                // are no cached notes to render. Once a snapshot has been
                // restored (or notes have streamed in), the background sync
                // is surfaced via the inline `syncingPill` instead.
                // "You aren't following anyone" is a conclusion, and it needs a
                // finished contact load behind it. Deriving it from the loading
                // flags alone made it true for the first seconds of every
                // launch, before anything had started. FollowingFeedState owns
                // that rule and is unit-tested; the view only asks.
                let isFollowSetFeed = feedService.isFollowSetMode
                    || (feedService.feedMode == .media && feedService.mediaFeedMode == .following)
                let placeholder = FollowingFeedState.decide(
                    followCount: feedService.followedPubkeys.count,
                    hasAttemptedContactLoad: feedService.hasAttemptedContactLoad,
                    isLoadingContacts: feedService.isLoadingContacts,
                    isLoadingFeed: feedService.isLoadingFeed,
                    hasNotes: !feedService.notes.isEmpty
                )
                let showLoadingContacts = isFollowSetFeed && placeholder == .loading
                let showEmptyState = isFollowSetFeed && placeholder == .empty

                if feedService.feedMode == .reels {
                    reelsFeedView
                } else if relayManager.isImporting && feedService.notes.isEmpty {
                    // The relay is busy importing (I use Nostr's "Keep it
                    // running"), so nothing loads until it's back.
                    importingFeedView
                } else if showLoadingContacts {
                    loadingContactsView
                } else if feedService.feedMode == .discovery && feedService.isLoadingExtendedNetwork && feedService.notes.isEmpty {
                    loadingExtendedNetworkView
                } else if feedService.feedMode == .popular && feedService.isLoadingPopular && feedService.notes.isEmpty {
                    loadingPopularView
                } else if showEmptyState {
                    emptyStateView
                } else if feedService.feedMode == .discovery && feedService.extendedNetworkPubkeys.isEmpty && !feedService.isLoadingFeed && !feedService.isLoadingExtendedNetwork {
                    emptyDiscoveryStateView
                } else if feedService.feedMode == .popular && feedService.filteredNotes.isEmpty && !feedService.isLoadingFeed && !feedService.isLoadingPopular {
                    emptyPopularStateView
                } else {
                    feedList
                }
            }
            .transition(.opacity)
            .animation(Motion.fade, value: configService.activeAccountHexPubkey)
        }
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                ChromeMorphCapsule(alignment: .leading, isEnabled: isCompactWidth) {
                    feedLeadingToolbar
                }
            }
            .hidingSharedToolbarBackground()

            ToolbarItem(placement: .navigationBarTrailing) {
                ChromeMorphCapsule(alignment: .trailing, isEnabled: isCompactWidth) {
                    ZStack(alignment: .trailing) {
                        ChromeFold(anchor: .trailing, isEnabled: isCompactWidth) {
                            // Width only: the pill's vertical padding makes it
                            // taller than the bar's proposal, which must not
                            // demote the row to the menu.
                            ViewThatFits(in: .horizontal) {
                                feedTrailingToolbarInline
                                feedTrailingToolbarMenu
                            }
                            .padding(.horizontal, 3)
                        }
                        // The lone layout button fades in as the full row
                        // fades out, centred in the circle the pill folds to.
                        // Feeds without layouts get the filter menu there
                        // instead, so the circle is never empty.
                        if isCompactWidth && feedService.feedMode != .reels {
                            ChromeFold(anchor: .trailing, inverted: true) {
                                if currentFeedHasLayouts {
                                    layoutModeButton
                                        .padding(.horizontal, 4)
                                } else {
                                    feedTrailingToolbarMenu
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .tutorialAnchor(TutorialContent.feedToolbar)
            }
            .hidingSharedToolbarBackground()
        }
        #endif
        .onAppear {
            feedService.markViewed()
            rebuildRowDataCache(immediate: true)
            rebuildThreadsIfNeeded(immediate: true)
            // Resume if previously paused (e.g. view disappeared while in menu bar).
            if feedService.isPaused {
                feedService.resumeFeed()
                return
            }
            // Wait for relay to be ready before loading feed to avoid OOM
            // from relay + feed + media all starting simultaneously. This covers
            // the case where the relay was ALREADY ready before the view appeared
            // (so FeedService's readiness observer's transition was missed/deduped).
            // Once-ready and follow-set/relay changes after this are driven by
            // FeedService.reconcileFeedSubscriptions via its relay-readiness observer.
            if relayManager.isReadyForConnections && feedService.notes.isEmpty && !feedService.isLoadingContacts {
                feedService.startInitialLoad()
            }
        }
        .sheet(item: $composeContext) { ctx in
            ComposeView(onDismiss: { composeContext = nil }, replyTo: ctx.replyTo, quoteTo: ctx.quoteTo, initialContent: ctx.initialContent, restoredDraftId: ctx.draftId)
                .environmentObject(nostrService)
                .environmentObject(configService)
        }
        .sheet(item: $modeComposer) { composer in
            Group {
                switch composer {
                case .divine:
                    DivineComposeView(onDismiss: { modeComposer = nil })
                case .article:
                    LongFormComposeView(flavor: .article, onDismiss: { modeComposer = nil })
                case .recipe:
                    LongFormComposeView(flavor: .recipe, onDismiss: { modeComposer = nil })
                case .listing:
                    MarketplaceSellView(onDismiss: { modeComposer = nil })
                case .poll:
                    PollComposeView(onDismiss: { modeComposer = nil })
                }
            }
            .environmentObject(nostrService)
            .environmentObject(configService)
        }
        #if !os(iOS)
        // iOS reopens the composer from SceneDelegate, over any open sheet.
        .onChange(of: pendingManager.editRequest?.id) { _, _ in
            guard let req = pendingManager.editRequest else { return }
            composeContext = ComposeContext(replyTo: req.replyTo, quoteTo: req.quoteTo, initialContent: req.content, draftId: req.draftId)
            pendingManager.editRequest = nil
        }
        #endif
        .sheet(isPresented: $showingDashboard) {
            FeedDashboardView(
                onOpenFeed: { mode in
                    showingDashboard = false
                    FeedDashboardStore.openOnFollowing(mode)
                },
                onDismiss: { showingDashboard = false }
            )
        }
        .sheet(isPresented: $showingFeedMenuEditor) {
            FeedMenuEditor(onDismiss: { showingFeedMenuEditor = false })
                #if os(macOS)
                .frame(minWidth: 360, minHeight: 520)
                #endif
        }
        .sheet(item: Binding<IdentifiableString?>(
            get: { showingNoteId.map { IdentifiableString(id: $0) } },
            set: { showingNoteId = $0?.id }
        )) { noteId in
            NoteDetailViewWrapper(noteId: noteId.id, onDismiss: { showingNoteId = nil })
                .environmentObject(nostrService)
                .environmentObject(configService)
        }
        .overlay { FillYourFeedOverlay() }
        .sheet(item: $showingProfileKey) { p in
            ProfileView(pubkey: p.id, onDismiss: { showingProfileKey = nil })
                .environmentObject(nostrService)
                .environmentObject(configService)
        }
        .mediaViewer(item: $showingMediaUrl, namespace: mediaZoom)
        .sheet(item: $showingArticle) { route in
            // In a stack so a comment under the article can open as a note.
            NavigationStack {
                ArticleReaderView(note: route.note)
            }
                .environmentObject(nostrService)
                // A Mac sheet sizes to its content; on iPhone a 520pt minimum
                // is wider than the screen, so the reader drew off both edges.
                #if os(macOS)
                .frame(minWidth: 520, minHeight: 480)
                #endif
        }
        .sheet(isPresented: $isShowingGridMediaViewer) {
            ZStack {
                Color.black
                    .opacity(max(0.1, 1.0 - (abs(galleryDragOffset.height) / 500.0)))
                    .ignoresSafeArea()
                
                MediaPagerView(items: gridMediaSnapshot.map { $0.id }, selection: $selectedGridMediaNoteId, enableKeyboardNavigation: true, showsPositionBar: false) { noteId in
                    if let note = gridMediaSnapshot.first(where: { $0.id == noteId }), let firstMediaURL = note.mediaURLs.first {
                        FeedMediaViewer(url: firstMediaURL, enableDragDismiss: false, onDismiss: { isShowingGridMediaViewer = false })
                            #if os(iOS)
                            .transition(.opacity.animation(Motion.media))
                            #endif
                    }
                }
                .offset(y: galleryDragOffset.height)
                .scaleEffect(max(0.8, 1.0 - (abs(galleryDragOffset.height) / 1000.0)))
                .gesture(
                    DragGesture()
                        .onChanged { gesture in
                            if abs(gesture.translation.height) > abs(gesture.translation.width) || galleryDragOffset.height != 0 {
                                galleryDragOffset = CGSize(width: 0, height: gesture.translation.height)
                            }
                        }
                        .onEnded { gesture in
                            if abs(galleryDragOffset.height) > 120 {
                                withAnimation(Motion.dismiss) {
                                    isShowingGridMediaViewer = false
                                    galleryDragOffset = .zero
                                }
                            } else {
                                withAnimation(Motion.snapBack) {
                                    galleryDragOffset = .zero
                                }
                            }
                        }
                )
            }
            .ignoresSafeArea()
            .onDisappear {
                selectedGridMediaNoteId = nil
            }
        }
        .alert(String(localized: "feed.alert.sensitiveContent.title"), isPresented: $showingGlobalEveryoneWarning) {
            Button(String(localized: "feed.alert.sensitiveContent.proceed"), role: .destructive) {
                setGlobalShowsEveryone(true)
            }
            Button(String(localized: "feed.alert.sensitiveContent.cancel"), role: .cancel) {}
        } message: {
            Text("Everyone shows posts from people outside your Web of Trust, unfiltered. Expect spam and sensitive content.")
        }
        .onChange(of: configService.config.globalShowsEveryone) { _, _ in reloadForTrustScope() }
        .sheet(item: $selectedListing) { listing in
            MarketplaceListingSheet(listing: listing, onOpenProfile: { showingProfileKey = IdentifiableString(id: $0) })
                .environmentObject(nostrService)
        }
        .sheet(item: $playingStream) { stream in
            LiveStreamPlayerView(stream: stream, onBlocked: { pubkey in
                liveService.removeStreams(byHost: pubkey)
            })
            .environmentObject(nostrService)
            .environmentObject(configService)
        }
    }
}
