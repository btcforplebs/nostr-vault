import SwiftUI

extension MenuBarView {
    @ViewBuilder
    var sidebarLayout: some View {
                    // MARK: - Premium Desktop Sidebar Layout
                    HStack(spacing: 0) {
                        // LEFT SIDEBAR
                        VStack(alignment: .leading, spacing: 0) {
                            // Brand Header
                            HStack(spacing: 10) {
                                Image(systemName: "server.rack")
                                    .font(.appSystem(size: 18, weight: .bold))
                                    .foregroundColor(.havenPurple)
                                Text("Nostr Vault")
                                    .font(.appSystem(size: 18, weight: .bold))
                                    .foregroundColor(.white)
                                Spacer()
                                
                                // Live status dot
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(relayManager.isBooting ? Color.yellow : (relayManager.isRunning && relayManager.isWotSyncing ? Color.orange : (relayManager.isRunning ? Color.green : Color.red)))
                                        .frame(width: 8, height: 8)
                                    Text(relayManager.isBooting ? "Booting" : (relayManager.isRunning && relayManager.isWotSyncing ? "Syncing" : (relayManager.isRunning ? "Online" : "Offline")))
                                        .font(.appSystem(size: 10, weight: .semibold))
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 20)
                            
                            Divider()
                                .background(Color.platformSeparator)
                                .padding(.bottom, 12)
                            
                            // Active Account Section
                            Button(action: {
                                if hasMultipleAccounts {
                                    showingAccountSwitcher.toggle()
                                } else {
                                    selectedTab = .profile
                                }
                            }) {
                                HStack(spacing: 12) {
                                    AvatarView(
                                        url: nostrService.profiles[activeHex]?.pictureURL,
                                        pubkey: activeHex,
                                        size: 32
                                    )
                                    .id(activeHex)
                                    .overlay(
                                        Circle()
                                            .stroke(
                                                isOwner ? Color.havenPurple.opacity(0.4) : Color.orange.opacity(0.8),
                                                lineWidth: isOwner ? 1.5 : 2
                                            )
                                    )

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(nostrService.profiles[activeHex]?.bestName ?? (isOwner ? "Owner" : "User"))
                                            .font(.appSystem(size: 13, weight: .semibold))
                                            .foregroundColor(.white)
                                            .lineLimit(1)
                                        Text(isOwner ? "Owner Key" : "Whitelisted")
                                            .font(.appSystem(size: 10))
                                            .foregroundColor(.secondary)
                                    }
                                    
                                    Spacer()
                                    
                                    if hasMultipleAccounts {
                                        Image(systemName: "chevron.up.chevron.down")
                                            .font(.appSystem(size: 10))
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color.white.opacity(0.04))
                                .cornerRadius(8)
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 16)
                            .popover(isPresented: $showingAccountSwitcher, arrowEdge: .trailing) {
                                AccountSwitcherView(configService: configService)
                            }
                            .contextMenu {
                                Button("View Profile") { selectedTab = .profile }
                                if hasMultipleAccounts {
                                    Divider()
                                    ForEach(configService.allAccountNpubs, id: \.self) { npub in
                                        let activeNpub = configService.config.activeAccountNpub.trimmingCharacters(in: .whitespacesAndNewlines)
                                        let isOwner = npub == configService.config.ownerNpub
                                        let hex = Bech32.decode(npub)?.hexString ?? ""
                                        let profile = nostrService.profiles[hex]
                                        AccountMenuItem(
                                            npub: npub,
                                            name: profile?.bestName ?? (isOwner ? "Owner" : AccountSwitcherIdentity.shortNpub(npub)),
                                            pictureURL: profile?.pictureURL,
                                            isActive: activeNpub.isEmpty ? isOwner : npub == activeNpub,
                                            unread: unreadStore.count(npub: npub)
                                        ) {
                                            configService.switchActiveAccount(to: npub)
                                        }
                                    }
                                }
                            }

                            // New Post (macOS only: showingCompose is macOS-gated)
                            #if os(macOS)
                            // None for a read-only sign-in: it can't sign a post.
                            if configService.activeAccountCanSign {
                                Button(action: { showingCompose = true }) {
                                    HStack(spacing: 8) {
                                        Image(systemName: "square.and.pencil")
                                            .font(.appSystem(size: 13, weight: .bold))
                                        Text("New Post")
                                            .font(.appSystem(size: 13, weight: .semibold))
                                        Spacer()
                                    }
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 9)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(Color.havenPurple)
                                    )
                                }
                                .buttonStyle(.plain)
                                .help("New Post (⌘N)")
                                .padding(.horizontal, 12)
                                .padding(.bottom, 12)
                            }
                            #endif

                            // Sidebar Tabs
                            VStack(spacing: 4) {
                                SidebarTabButton(icon: "list.bullet.rectangle.portrait", title: "Feed", isSelected: selectedTab == .feed) {
                                    selectedTab = .feed
                                }
                                
                                SidebarTabButton(icon: "magnifyingglass", title: "Search", isSelected: selectedTab == .search) {
                                    selectedTab = .search
                                }

                                // Profile tab with live account avatar
                                Button(action: { selectedTab = .profile }) {
                                    HStack(spacing: 12) {
                                        AvatarView(url: nostrService.profiles[activeHex]?.pictureURL, pubkey: activeHex, size: 20)
                                            .id(activeHex)
                                            .overlay(
                                                Circle()
                                                    .stroke(selectedTab == .profile ? Color.white.opacity(0.6) : Color.clear, lineWidth: 1.5)
                                            )
                                            .frame(width: 20, height: 20)
                                            .zapFlightOrigin()

                                        Text("My Profile")
                                            .font(.appSystem(size: 13, weight: selectedTab == .profile ? .semibold : .medium))
                                            .foregroundColor(selectedTab == .profile ? .white : .secondary)

                                        Spacer()
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(selectedTab == .profile ? Color.havenPurple : Color.clear)
                                    )
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                SidebarTabButton(icon: "doc.text.image", title: "Relay", isSelected: selectedTab == .relay) {
                                    selectedTab = .relay
                                }

                                SidebarTabButton(icon: "note.text", title: "Notes", isSelected: selectedTab == .notes) {
                                    selectedTab = .notes
                                }
                                // The Vault (VaultView): what the return pill's arrow points at.
                                .vaultAnchor(.leading)

                                SidebarTabButton(icon: "photo.on.rectangle", title: "Media", isSelected: selectedTab == .media) {
                                    selectedTab = .media
                                }

                                SidebarTabButton(icon: "gearshape", title: "Settings", isSelected: selectedTab == .settings) {
                                    selectedTab = .settings
                                }
                            }
                            .padding(.horizontal, 8)
                            
                            Spacer()
                            
                            // Quick restart/start relay action inside sidebar footer
                            VStack(spacing: 8) {
                                Button(action: {
                                    if relayManager.isRunning {
                                        relayManager.stopRelay {
                                            relayManager.startRelay(config: configService.config)
                                        }
                                    } else {
                                        relayManager.startRelay(config: configService.config)
                                    }
                                }) {
                                    HStack {
                                        Image(systemName: relayManager.isRunning ? "arrow.clockwise.circle.fill" : "play.circle.fill")
                                            .foregroundColor(relayManager.isRunning ? .orange : .green)
                                        Text(relayManager.isBooting ? "Booting..." : (relayManager.isRunning ? "Restart Vault" : "Start Vault"))
                                            .font(.appSystem(size: 13, weight: .semibold))
                                        Spacer()
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(relayManager.isRunning ? Color.orange.opacity(0.1) : Color.green.opacity(0.1))
                                    .cornerRadius(8)
                                }
                                .buttonStyle(.plain)
                                .disabled(relayManager.isBooting)
                                
                                #if os(macOS)
                                Button("Quit Nostr Vault") {
                                    NSApp.terminate(nil)
                                }
                                .buttonStyle(.plain)
                                .foregroundColor(.secondary)
                                .font(.appSystem(size: 12))
                                .padding(.top, 4)
                                #endif
                            }
                            .padding(16)
                        }
                        .frame(width: 220)
                        .background(Color(red: 0.1, green: 0.1, blue: 0.13))
                        
                        Divider()
                            .background(Color.platformSeparator)
                        
                        // MAIN CONTENT AREA
                        ZStack {
                            Color.platformWindowBackground
                                .ignoresSafeArea()
                            
                            switch selectedTab {
                            case .feed:
                                FeedView()
                                    .transition(.opacity)
                            case .search:
                                SearchView()
                                    .transition(.opacity)
                            case .media:
                                MediaTabView()
                                    .environmentObject(relayManager)
                                    .environmentObject(configService)
                                    .environmentObject(nostrService)
                                    .environmentObject(StatsService.shared)
                                    .transition(.opacity)
                            case .profile:
                                MyProfileView(pubkey: activeHex)
                                    .id(activeHex)
                                    .environmentObject(nostrService)
                                    .environmentObject(configService)
                                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                            case .relay:
                                DashboardView(isSidebar: true)
                                    .environmentObject(relayManager)
                                    .environmentObject(configService)
                                    .environmentObject(nostrService)
                                    .environmentObject(StatsService.shared)
                                    .transition(.opacity)
                            case .notes:
                                VaultView()
                                    .environmentObject(configService)
                                    .environmentObject(nostrService)
                                    .environmentObject(relayManager)
                                    .transition(.opacity)
                            case .settings:
                                SettingsView(isEmbedded: true, paneRequest: $settingsPaneRequest)
                                    .environmentObject(relayManager)
                                    .environmentObject(configService)
                                    .environmentObject(nostrService)
                                    .environmentObject(StatsService.shared)
                                    .transition(.opacity)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .animation(Motion.toggle, value: selectedTab)
                        .animation(Motion.fade, value: activeHex)
                    }
                    #if os(macOS)
                    // What came in while the app was away, beside the Vault
                    // (Notes) row; a tap opens it.
                    .overlay { ReturnPillLayer() }
                    .onReceive(NotificationCenter.default.publisher(for: .havenOpenVault)) { _ in
                        selectedTab = .notes
                    }
                    #endif
    }
}
