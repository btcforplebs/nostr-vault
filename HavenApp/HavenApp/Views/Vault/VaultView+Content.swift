import SwiftUI
import PhotosUI

extension VaultView {
    // MARK: - Header View

    @ViewBuilder
    func headerView(isNarrow: Bool) -> some View {
        VStack(spacing: 12) {
            #if os(macOS)
            if isNarrow {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        modeView
                        Spacer()
                        refreshButton
                        searchToggleButton
                    }
                    if viewMode == .notes {
                        ScrollView(.horizontal, showsIndicators: false) {
                            filterView
                        }
                    } else if viewMode == .likes {
                        ScrollView(.horizontal, showsIndicators: false) {
                            likesFilterView
                        }
                    } else if viewMode == .zaps {
                        ScrollView(.horizontal, showsIndicators: false) {
                            zapsFilterView
                        }
                    } else if viewMode == .followers {
                        ScrollView(.horizontal, showsIndicators: false) {
                            followersFilterView
                        }
                    }
                    searchBar
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        modeView
                        Spacer()
                        if viewMode == .notes {
                            filterView
                        } else if viewMode == .likes {
                            likesFilterView
                        } else if viewMode == .zaps {
                            zapsFilterView
                        } else if viewMode == .followers {
                            followersFilterView
                        }
                        refreshButton
                        searchToggleButton
                        compactToggleButton
                    }
                    searchBar
                }
            }
            #endif
        }
        .frame(maxWidth: .infinity)
        #if os(macOS)
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Color.platformSecondaryGroupedBackground)
        #endif
    }

    // MARK: - macOS viewContent (used for non-iOS body path)

    var viewContent: some View {
        viewContentBase
        // A filter tap's count lands with the rebuilt list (as on iOS).
        .onChange(of: displayPass) { _, _ in filterListLanded() }
        .onChange(of: viewMode) { _, _ in pendingFilterNote = nil }
        .modifier(VaultChangeHandlers(
            viewMode: viewMode,
            likesFilter: likesFilter,
            zapsFilter: zapsFilter,
            contentFilter: contentFilter,
            noteScopeKey: "\(noteScope.rawValue).\(recipesOnly)",
            eventsCount: nostrService.events.count,
            blacklistedNpubs: configService.config.blockedNpubsPerAccount[configService.config.activeAccountNpub.isEmpty ? configService.config.ownerNpub : configService.config.activeAccountNpub] ?? (configService.config.activeAccountNpub.isEmpty ? configService.config.blacklistedNpubs : []),
            activeAccountNpub: configService.config.activeAccountNpub,
            wotCount: feedService.wotPubkeys.count,
            followCount: feedService.followedPubkeys.count,
            onResetAndUpdate: {
                maxDisplayedItems = 50
                notesHasLoadedOnce = false
                scheduleUpdateDisplayData()
            },
            onUpdate: { scheduleUpdateDisplayData() },
            onViewModeChange: { newMode in
                updateDisplayData()
                markTabViewed(newMode)
                if newMode == .likes {
                    fetchMissingLikedNotes()
                    updateLikesSettleState()
                }
                if newMode == .zaps {
                    fetchMoreZapReceipts()
                    fetchMissingZappedNotes()
                    updateZapsSettleState()
                }
            },
            onEventsChange: {
                scheduleUpdateDisplayData()
                checkForNewNotifications()
                if viewMode == .likes && likesFilter == .myLikes {
                    fetchMissingLikedNotes()
                }
                if viewMode == .zaps {
                    fetchMoreZapReceipts()
                    fetchMissingZappedNotes()
                }
            }
        ))
        .onChange(of: likesFilter) { _, _ in
            likesHasLoadedOnce = false
            likesInitialSettled = false
            updateLikesSettleState()
        }
        .onChange(of: zapsFilter) { _, _ in
            zapsHasLoadedOnce = false
            zapsInitialSettled = false
            updateZapsSettleState()
        }
        .onChange(of: configService.config.zapsOnlyMode) { _, newValue in
            if newValue && viewMode == .likes {
                withAnimation(Motion.toggle) { viewMode = .notes }
            }
        }
        // Your accounts tagging each other came in or left the list.
        .onChange(of: configService.config.notifyOwnAccountTags) { _, _ in
            scheduleUpdateDisplayData()
            if showsOtherAccounts { loadOtherAccountActivity() }
        }
        .onChange(of: configService.config.activeAccountNpub) { _, _ in
            notesHasLoadedOnce = false
            likesHasLoadedOnce = false
            likesInitialSettled = false
            zapsHasLoadedOnce = false
            zapsInitialSettled = false
            zapReceiptsFetchGeneration = nil
            likedNotesFetchGeneration = nil
            zapReceiptCache = [:]
            refreshAll()
        }
        .onChange(of: nostrService.isFetching) { _, _ in
            if viewMode == .likes { updateLikesSettleState() }
            if viewMode == .zaps { updateZapsSettleState() }
        }
        .onChange(of: relayManager.isBooting) { _, _ in
            if viewMode == .likes { updateLikesSettleState() }
            if viewMode == .zaps { updateZapsSettleState() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .feedInjectionComplete)) { _ in
            refreshAll(.incremental)
        }
        .onReceive(NotificationCenter.default.publisher(for: .mediaNotFoundChanged)) { _ in
            scheduleUpdateDisplayData()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openRelayDashboard)) { _ in
            showingRelayDashboard = true
        }
        // Not iOS-only: this is the macOS body, and gating these meant a notification
        // tap that reached the Notes tab still showed whatever mode was last open.
        .onReceive(NotificationCenter.default.publisher(for: .havenOpenRelayLikes)) { _ in
            // In Zaps Only mode the Likes tab is hidden — route to Notes instead.
            let target: ViewMode = configService.config.zapsOnlyMode ? .notes : .likes
            withAnimation(Motion.toggle) { viewMode = target }
            if target == .notes { noteScope = .notes; recipesOnly = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: .havenOpenRelayNotes)) { note in
            openNotes(note)
        }
        .onReceive(NotificationCenter.default.publisher(for: .havenOpenRelayZaps)) { _ in
            withAnimation(Motion.toggle) { viewMode = .zaps }
        }
        .onReceive(NotificationCenter.default.publisher(for: .havenOpenRelayFollowers)) { _ in
            withAnimation(Motion.toggle) { viewMode = .followers }
        }
        .sheet(item: Binding<IdentifiableString?>(
            get: { showingProfilePubkey.map { IdentifiableString(id: $0) } },
            set: { showingProfilePubkey = $0?.id }
        )) { p in
            ProfileView(pubkey: p.id, onDismiss: { showingProfilePubkey = nil })
        }
        .sheet(item: Binding<IdentifiableString?>(
            get: { showingNoteId.map { IdentifiableString(id: $0) } },
            set: { showingNoteId = $0?.id }
        )) { noteId in
            NoteDetailViewWrapper(noteId: noteId.id, onDismiss: { showingNoteId = nil })
                .environmentObject(nostrService)
                .environmentObject(configService)
        }
        #if os(iOS)
        .sheet(isPresented: $showingRelayDashboard) {
            NavigationView {
                relayDashboardContent
                    .environmentObject(relayManager)
                    .environmentObject(configService)
                    .environmentObject(nostrService)
                    .environmentObject(StatsService.shared)
                    .navigationTitle("")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarBackground(.hidden, for: .navigationBar)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingRelayDashboard = false }
                        }
                        if vaultTabHostsMedia {
                            ToolbarItem(placement: .principal) {
                                Label(VaultDashboard.title, systemImage: VaultDashboard.symbol)
                                    .labelStyle(.titleAndIcon)
                                    .font(.appSystem(size: 17, weight: .bold, design: .rounded))
                            }
                        }
                    }
            }
        }
        #endif
    }

    private var viewContentBase: some View {
        viewContentPlatform
        .onAppear {
            if relayManager.isRunning && !relayManager.isBooting {
                if feedService.followedPubkeys.isEmpty {
                    feedService.refresh()
                }
                // Only refresh if SceneDelegate didn't already handle reconnection
                // within the last 3 seconds (prevents double-reset race condition)
                let recentlyReconnected: Bool
                if let lastReconnect = nostrService.lastForegroundReconnectTime {
                    recentlyReconnected = Date().timeIntervalSince(lastReconnect) < 3.0
                } else {
                    recentlyReconnected = false
                }
                if nostrService.connectionStatus == "Disconnected" && !recentlyReconnected {
                    refreshAll()
                } else {
                    // Sockets are live: keep them, just ask the embedded relay
                    // to catch up and top up the live subscriptions.
                    refreshAll(.incremental)
                }
                initialLoad = true
                // Eagerly compute display data so tabs don't flash an empty state
                updateDisplayData()
            }
            if !hasEstablishedNotificationBaseline {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    establishNotificationBaseline()
                }
            }
        }
        .onChange(of: relayManager.isBooting) { _, isBooting in
            if !isBooting && relayManager.isRunning {
                refreshAll()
                initialLoad = true
                // Re-establish baseline after boot settles so initial events don't trigger highlights
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    establishNotificationBaseline()
                }
            }
        }
        .onChange(of: relayManager.isRunning) { _, isRunning in
            if isRunning && !relayManager.isBooting {
                refreshAll()
                initialLoad = true
            }
        }
    }
}
