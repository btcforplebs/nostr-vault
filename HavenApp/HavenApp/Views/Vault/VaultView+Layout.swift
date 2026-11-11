import SwiftUI
import PhotosUI

extension VaultView {
    // MARK: - Platform Layout

    @ViewBuilder
    var viewContentPlatform: some View {
        #if os(iOS)
        // Vault tab: full-bleed layout so content scrolls behind
        // the transparent navigation bar, matching the glass toolbar effect.
        ZStack {
            Color.platformWindowBackground.ignoresSafeArea()

            // Messages is a page of its own: the inbox, in this stack and bar.
            if viewMode == .messages {
                DMInboxView()
            } else {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    Color.clear.frame(height: 0).id(Self.topAnchor)
                    listContent

                    if sparseNotesScope {
                        loadOlderButton
                    } else if !displayNotes.isEmpty || !displayLikedNotes.isEmpty {
                        Color.clear
                            .frame(height: 1)
                            .padding(.bottom, 20)
                            .onAppear {
                                if !nostrService.isFetching && !displayNotes.isEmpty {
                                    loadMore()
                                }
                            }
                            .id(nostrService.events.count)
                    }
                }
                .tabBarBottomPadding()
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollDirectionTracking(feedService: feedService)
            // Tapping the Relay tab again: back to the list from a note, or
            // up to the top, as the Feed tab does.
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("RelayScrollToTop"))) { _ in
                if !navigationPath.isEmpty {
                    navigationPath = NavigationPath()
                } else {
                    withAnimation(Motion.scrollJump) { proxy.scrollTo(Self.topAnchor, anchor: .top) }
                }
            }
            }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            // The inbox has its own compose button in the bar.
            if viewMode != .messages {
            ChromeFold(anchor: .bottomTrailing) {
                Button(action: { showingRelayDashboard = true }) {
                    HStack(spacing: 6) {
                        Image(systemName: vaultTabHostsMedia ? VaultDashboard.symbol : "antenna.radiowaves.left.and.right")
                            .font(.appSystem(size: 15, weight: .bold))
                        Text(vaultTabHostsMedia ? "Vault" : "Relay")
                            .font(.appSystem(size: 14, weight: .bold, design: .rounded))
                    }
                    .foregroundColor(.white)
                    .frame(height: 48)
                    .padding(.horizontal, 18)
                    .background(
                        Capsule()
                            .fill(statusColor)
                            .shadow(color: statusColor.opacity(0.35), radius: 8, x: 0, y: 4)
                    )
                }
                .tutorialAnchor(TutorialContent.vaultRelay, isActive: showsVaultTutorialAnchors)
                // Shares the row above the tab bar with the music mini player.
                .modifier(FloatingButtonSlot())
                .hoverEffect(.lift)
            }
            }
        }
        #else
        GeometryReader { geometry in
            ZStack {
                Color.platformWindowBackground.ignoresSafeArea()

                // The dashboard shows at any width. The menu bar's signal button opens
                // it, and the popped-out window is often wider than 680, where it was
                // never drawn: the click only switched tabs.
                if showingRelayDashboard {
                    VStack(spacing: 0) {
                        HStack {
                            Text("Relay Dashboard")
                                .font(.appSystem(size: 16, weight: .bold))
                                .foregroundColor(.primary)
                            Spacer()
                            Button("Done") {
                                showingRelayDashboard = false
                            }
                            .keyboardShortcut(.defaultAction)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                        .background(Color.platformConsoleHeaderBackground)

                        Divider()

                        DashboardView()
                            .environmentObject(relayManager)
                            .environmentObject(configService)
                            .environmentObject(nostrService)
                            .environmentObject(StatsService.shared)
                    }
                } else if geometry.size.width > 680 {
                    VStack(spacing: 0) {
                        desktopHeaderView

                        Divider()

                        if viewMode == .messages {
                            DMInboxView()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                        ScrollView {
                            listContent

                            if !displayNotes.isEmpty || !displayLikedNotes.isEmpty {
                                Color.clear
                                    .frame(height: 1)
                                    .padding(.bottom, 20)
                                    .onAppear {
                                        if !nostrService.isFetching && !displayNotes.isEmpty {
                                            loadMore()
                                        }
                                    }
                                    .id(nostrService.events.count)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        // Feeds the filter-note bubble in the banner stack.
                        .filterNoteHost(filterNote)
                        }
                    }
                    .clipped()
                } else {
                    compactViewContent
                }
            }
        }
        #endif
    }

    // MARK: - Compact View (narrow macOS / fallback)

    @ViewBuilder
    var compactViewContent: some View {
        VStack(spacing: 0) {
            headerView

            Divider()

            if viewMode == .messages {
                DMInboxView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
            ScrollView {
                VStack(spacing: 0) {
                    listContent

                    if !displayNotes.isEmpty || !displayLikedNotes.isEmpty {
                        Color.clear
                            .frame(height: 1)
                            .padding(.bottom, 20)
                            .onAppear {
                                if !nostrService.isFetching && !displayNotes.isEmpty {
                                    loadMore()
                                }
                            }
                            .id(nostrService.events.count)
                    }
                }
                .tabBarBottomPadding()
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollDirectionTracking(feedService: feedService)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .filterNoteHost(filterNote)
            }
        }
        #if os(iOS)
        .overlay(alignment: .bottomTrailing) {
            ChromeFold(anchor: .bottomTrailing) {
                Button(action: { showingRelayDashboard = true }) {
                    HStack(spacing: 6) {
                        Image(systemName: vaultTabHostsMedia ? VaultDashboard.symbol : "antenna.radiowaves.left.and.right")
                            .font(.appSystem(size: 15, weight: .bold))
                        Text(vaultTabHostsMedia ? "Vault" : "Relay")
                            .font(.appSystem(size: 14, weight: .bold, design: .rounded))
                    }
                    .foregroundColor(.white)
                    .frame(height: 48)
                    .padding(.horizontal, 18)
                    .background(
                        Capsule()
                            .fill(statusColor)
                            .shadow(color: statusColor.opacity(0.35), radius: 8, x: 0, y: 4)
                    )
                }
                .tutorialAnchor(TutorialContent.vaultRelay, isActive: showsVaultTutorialAnchors)
                // Shares the row above the tab bar with the music mini player.
                .modifier(FloatingButtonSlot())
                .hoverEffect(.lift)
            }
        }
        #endif
    }

    // MARK: - macOS Desktop Header

    @ViewBuilder
    var desktopHeaderView: some View {
        VStack(spacing: 12) {
            #if os(macOS)
            macModeFilterRow
            #endif

            searchBar
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal)
        .padding(.vertical, 12)
        .background(Color.platformSecondaryGroupedBackground)
    }
}
