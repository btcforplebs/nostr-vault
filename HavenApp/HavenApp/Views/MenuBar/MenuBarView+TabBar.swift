import SwiftUI

extension MenuBarView {
    @ViewBuilder
    var tabBarLayout: some View {
                    // Original Narrow Layout (Menu Bar dropdown)
                    VStack(spacing: 0) {
                        // MARK: - Header
                        HStack {
                            Label("Nostr Vault", systemImage: "server.rack")
                                .font(.appSystem(size: 16, weight: .semibold))
                                .foregroundColor(.havenPurple)
                            
                            Spacer()
                            
                            if relayManager.isBooting || relayManager.isWotSyncing {
                                Text(relayManager.bootStatusMessage)
                                    .font(.appSystem(size: 11, weight: .medium))
                                    .foregroundColor(.secondary)
                                    .transition(.opacity)
                            }
                            
                            HStack(spacing: 6) {
                                // New Post (macOS only: showingCompose is macOS-gated)
                                #if os(macOS)
                                Button(action: { showingCompose = true }) {
                                    Image(systemName: "square.and.pencil")
                                        .font(.appSystem(size: 16, weight: .medium))
                                        .foregroundColor(.havenPurple)
                                        .frame(width: 28, height: 28)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("New Post (⌘N)")
                                #endif

                                // Restart/start relay icon button
                                Button(action: {
                                    if relayManager.isRunning {
                                        relayManager.stopRelay {
                                            relayManager.startRelay(config: configService.config)
                                        }
                                    } else {
                                        relayManager.startRelay(config: configService.config)
                                    }
                                }) {
                                    Image(systemName: relayManager.isRunning ? "arrow.clockwise.circle" : "play.circle")
                                        .font(.appSystem(size: 16, weight: .medium))
                                        .foregroundColor(relayManager.isBooting ? .orange : (relayManager.isRunning ? .orange.opacity(0.8) : .secondary))
                                        .frame(width: 28, height: 28)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(relayManager.isBooting)
                                .help(relayManager.isBooting ? "Booting..." : (relayManager.isRunning ? "Restart Relay" : "Start Relay"))

                                // Signal icon → relay dashboard
                                Button(action: {
                                    selectedTab = .relay
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                        NotificationCenter.default.post(name: .openRelayDashboard, object: nil)
                                    }
                                }) {
                                    ZStack(alignment: .topTrailing) {
                                        Image(systemName: "antenna.radiowaves.left.and.right")
                                            .font(.appSystem(size: 16, weight: .medium))
                                            .foregroundColor(
                                                relayManager.isBooting ? .orange :
                                                (relayManager.isRunning && relayManager.isWotSyncing ? .orange :
                                                (relayManager.isRunning ? Color(red: 0.2, green: 0.85, blue: 0.5) : .secondary))
                                            )
                                            .scaleEffect(relayManager.isRunning && !relayManager.isBooting && statusPulse ? 1.08 : 1.0)
                                            .animation(Motion.ambientPulse, value: statusPulse)
                                            .onAppear { statusPulse = Motion.ambientPulse != nil }
                                            .onChange(of: relayManager.isRunning) { _, running in
                                                statusPulse = running && Motion.ambientPulse != nil
                                            }

                                        // Tiny status dot overlay
                                        Circle()
                                            .fill(relayManager.isBooting ? Color.orange : (relayManager.isRunning && relayManager.isWotSyncing ? Color.orange : (relayManager.isRunning ? Color(red: 0.2, green: 0.85, blue: 0.5) : Color.red)))
                                            .frame(width: 5, height: 5)
                                            .offset(x: 2, y: -1)
                                    }
                                    .frame(width: 28, height: 28)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("Relay Dashboard")
                            }
                        }
                        .padding()
                        .background(Color.platformControlBackground)
                        
                        Divider()
                        
                        // MARK: - Content
                        ZStack {
                            Color.platformControlBackground // Darker background
                                .ignoresSafeArea()

                            switch selectedTab {
                            case .feed:
                                // Feed is disabled in narrow menu bar mode to prevent
                                // memory/CPU pressure from unbounded note loading.
                                VStack(spacing: 12) {
                                    Spacer()
                                    Image(systemName: "rectangle.expand.vertical")
                                        .font(.appSystem(size: 28, weight: .light))
                                        .foregroundColor(.secondary.opacity(0.6))
                                    Text("Open the full window to view your feed")
                                        .font(.appSystem(size: 12, weight: .medium))
                                        .foregroundColor(.secondary)
                                        .multilineTextAlignment(.center)
                                    Button(action: {
                                        #if os(macOS)
                                        openWindow(id: "viewer-window")
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                            NSApp.activate(ignoringOtherApps: true)
                                        }
                                        #endif
                                    }) {
                                        Text("Open Window")
                                            .font(.appSystem(size: 12, weight: .semibold))
                                            .foregroundColor(.white)
                                            .padding(.horizontal, 16)
                                            .padding(.vertical, 6)
                                            .background(Color.havenPurple)
                                            .cornerRadius(8)
                                    }
                                    .buttonStyle(.plain)
                                    Spacer()
                                }
                                .frame(maxWidth: .infinity)
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
                                DashboardView()
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
                                VStack(spacing: 12) {
                                    Spacer()
                                    Image(systemName: "gearshape")
                                        .font(.appSystem(size: 28, weight: .light))
                                        .foregroundColor(.secondary.opacity(0.6))
                                    Text("Open the full window to adjust settings")
                                        .font(.appSystem(size: 12, weight: .medium))
                                        .foregroundColor(.secondary)
                                        .multilineTextAlignment(.center)
                                    Button(action: {
                                        #if os(macOS)
                                        openWindow(id: "viewer-window")
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                            NSApp.activate(ignoringOtherApps: true)
                                        }
                                        #endif
                                    }) {
                                        Text("Open Window")
                                            .font(.appSystem(size: 12, weight: .semibold))
                                            .foregroundColor(.white)
                                            .padding(.horizontal, 16)
                                            .padding(.vertical, 6)
                                            .background(Color.havenPurple)
                                            .cornerRadius(8)
                                    }
                                    .buttonStyle(.plain)
                                    Spacer()
                                }
                                .frame(maxWidth: .infinity)
                                .transition(.opacity)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .animation(Motion.toggle, value: selectedTab)
                        .animation(Motion.fade, value: activeHex)

                        Divider()

                        // MARK: - Tabs (bottom nav)
                        HStack(spacing: 0) {
                                TabButton(icon: "list.bullet.rectangle.portrait", title: "Feed", isSelected: selectedTab == .feed) {
                                    selectedTab = .feed
                                }
                                .contextMenu {
                                    ForEach(FeedMode.menuModes, id: \.self) { mode in
                                        Button(action: {
                                            selectedTab = .feed
                                            feedService.switchMode(mode)
                                        }) {
                                            if feedService.feedMode == mode {
                                                Label(mode.rawValue, systemImage: "checkmark")
                                            } else {
                                                Text(mode.rawValue)
                                            }
                                        }
                                    }
                                }

                                TabButton(icon: "magnifyingglass", title: "Search", isSelected: selectedTab == .search) {
                                    selectedTab = .search
                                }

                                // Profile tab with live account avatar
                                Button(action: { selectedTab = .profile }) {
                                    VStack(spacing: 4) {
                                        AvatarView(url: nostrService.profiles[activeHex]?.pictureURL, pubkey: activeHex, size: 18)
                                            .id(activeHex)
                                            .overlay(
                                                Circle()
                                                    .stroke(
                                                        selectedTab == .profile ? Color.havenPurple : Color.clear,
                                                        lineWidth: 1.5
                                                    )
                                            )
                                            .scaleEffect(selectedTab == .profile ? 1.1 : 1.0)
                                        Text("Profile")
                                            .font(.appSystem(size: 10, weight: selectedTab == .profile ? .semibold : .regular))
                                    }
                                    .foregroundColor(selectedTab == .profile ? Color.havenPurple : .secondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                TabButton(icon: "doc.text.image", title: "Relay", isSelected: selectedTab == .relay) {
                                    selectedTab = .relay
                                }

                                TabButton(icon: "photo.on.rectangle", title: "Blossom", isSelected: selectedTab == .media) {
                                    selectedTab = .media
                                }

                                TabButton(icon: "gearshape", title: "Settings", isSelected: selectedTab == .settings) {
                                    selectedTab = .settings
                                }
                            }
                            .padding(.horizontal, 4)
                            .padding(.vertical, 8)
                            .background(Color.platformControlBackground)

                            Divider()

                        // MARK: - Footer
                        HStack(spacing: 20) {
                            // MARK: - Account Avatar / Switcher
                            Button(action: {
                                if hasMultipleAccounts {
                                    showingAccountSwitcher.toggle()
                                } else {
                                    selectedTab = .profile
                                }
                            }) {
                                ZStack(alignment: .bottomTrailing) {
                                    AvatarView(
                                        url: nostrService.profiles[activeHex]?.pictureURL,
                                        pubkey: activeHex,
                                        size: 26
                                    )
                                    .id(activeHex)
                                    .overlay(
                                        Circle()
                                            .stroke(
                                                isOwner ? Color.havenPurple.opacity(0.4) : Color.orange.opacity(0.8),
                                                lineWidth: isOwner ? 1.5 : 2
                                            )
                                    )

                                    // Badge when browsing as non-owner
                                    if !isOwner {
                                        Circle()
                                            .fill(Color.orange)
                                            .frame(width: 7, height: 7)
                                            .overlay(Circle().stroke(Color.black, lineWidth: 1))
                                            .offset(x: 1, y: 1)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .help(hasMultipleAccounts ? "Switch Account" : "My Profile")
                            .simultaneousGesture(
                                LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                                    if hasMultipleAccounts {
                                        showingAccountSwitcher = true
                                    }
                                }
                            )
                            .popover(isPresented: $showingAccountSwitcher, arrowEdge: .bottom) {
                                AccountSwitcherView(configService: configService)
                            }
                            .contextMenu {
                                Button("View Profile") { selectedTab = .profile }
                                if hasMultipleAccounts {
                                    Divider()
                                    ForEach(configService.allAccountNpubs, id: \.self) { npub in
                                        let activeNpub = configService.config.activeAccountNpub.trimmingCharacters(in: .whitespacesAndNewlines)
                                        let isOwner = npub == configService.config.ownerNpub
                                        let isActive = activeNpub.isEmpty ? isOwner : npub == activeNpub
                                        let hex = Bech32.decode(npub)?.hexString ?? ""
                                        let name = nostrService.profiles[hex]?.bestName ?? (isOwner ? "Owner" : String(npub.prefix(8)))
                                        
                                        Button {
                                            configService.switchActiveAccount(to: npub)
                                        } label: {
                                            if isActive {
                                                Label(name, systemImage: "checkmark")
                                            } else {
                                                Text(name)
                                            }
                                        }
                                    }
                                }
                            }
                            
                            // The third copy of "open the main window" lived here as a
                            // "Pop Out" button. It was dead on both platforms: on macOS
                            // MenuBarView now only ever renders with isPoppedOut == true
                            // (the window itself), and on iOS the entire action body was
                            // inside #if os(macOS), so it rendered a button whose closure
                            // was empty — it did nothing when tapped. Removed; the one
                            // remaining implementation is MacWindow.openMain.
                            
                            Spacer()

                            Button("Quit Nostr Vault") {
                                #if os(macOS)
                                NSApp.terminate(nil)
                                #endif
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(.secondary)
                            .font(.appSystem(size: 13))
                        }
                        .padding()
                        .background(Color.platformControlBackground)
                    }
    }
}
