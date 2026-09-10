import SwiftUI

struct MenuBarView: View {
    @ObservedObject var configService: ConfigService
    @ObservedObject var relayManager: RelayProcessManager
    @ObservedObject private var feedService = FeedService.shared
    #if os(macOS)
    @State private var selectedTab: Tab = .relay
    #else
    @State private var selectedTab: Tab = .feed
    #endif
    #if os(macOS)
    @Environment(\.openSettings) var openSettings
    @Environment(\.openWindow) var openWindow
    #else
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    #endif
    var isPoppedOut: Bool = false
    
    @ObservedObject private var nostrService = NostrService.shared
    @State private var inactivityTask: Task<Void, Never>?
    @State private var statusPulse = false
    @State private var showingOwnProfile = false
    @State private var showingAccountSwitcher = false
    #if os(macOS)
    @State private var showingCompose = false
    #endif

    @State private var activeHex: String = ConfigService.shared.activeAccountHexPubkey

    private var usesSidebarLayout: Bool {
        #if os(macOS)
        return isPoppedOut
        #else
        return horizontalSizeClass == .regular
        #endif
    }

    private var isOwner: Bool {
        configService.config.activeAccountNpub.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    private var hasMultipleAccounts: Bool {
        configService.allAccountNpubs.count > 1
    }
    
    enum Tab {
        case feed
        case search
        case media
        case profile
        case relay
        case notes
        case settings
    }
    
    var body: some View {
        ZStack {
            Group {
                if isPoppedOut || usesSidebarLayout {
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
                                        pubkey: activeHex
                                    )
                                    .id(activeHex)
                                    .frame(width: 32, height: 32)
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

                            // New Post (macOS only: showingCompose is macOS-gated)
                            #if os(macOS)
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

                                SidebarTabButton(icon: "photo.on.rectangle", title: "Blossom", isSelected: selectedTab == .media) {
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
                                        Text(relayManager.isBooting ? "Booting..." : (relayManager.isRunning ? "Restart Relay" : "Start Relay"))
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
                                ProfileView(pubkey: activeHex)
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
                                SettingsView(isEmbedded: true)
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
                } else {
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
                                ProfileView(pubkey: activeHex)
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
                                    ForEach(FeedMode.allCases, id: \.self) { mode in
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
                                        pubkey: activeHex
                                    )
                                    .id(activeHex)
                                    .frame(width: 26, height: 26)
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
            .disabled(relayManager.isImporting) // Disable interaction when importing

            // MARK: - Import Overlay
            if relayManager.isImporting {
                ZStack {
                    Color.black.opacity(0.8)
                        .ignoresSafeArea()
                    
                    VStack(spacing: 24) {
                        Text("Importing Notes")
                            .font(.appTitle2.bold())
                            .foregroundColor(.white)
                        
                        // Progress Bar Custom Style
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(relayManager.importStatusMessage)
                                    .font(.appCaption)
                                    .foregroundColor(.white.opacity(0.8))
                                Spacer()
                                Text("\(Int(relayManager.importProgress * 100))%")
                                    .font(.appCaption.monospaced())
                                    .foregroundColor(.white)
                            }
                            
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color.havenPurplePale)
                                        .frame(height: 6)
                                    
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(
                                            LinearGradient(
                                                gradient: Gradient(colors: [.havenPurple, .havenPurpleLight]),
                                                startPoint: .leading,
                                                endPoint: .trailing
                                            )
                                        )
                                        .frame(width: geo.size.width * relayManager.importProgress, height: 6)
                                }
                            }
                            .frame(height: 6)
                        }
                        .frame(width: 300)
                        
                        Text("Please keep the app open.")
                            .font(.appFootnote)
                            .foregroundColor(.white.opacity(0.5))
                        
                        Divider()
                            .background(Color.white.opacity(0.2))
                        
                        if relayManager.importProgress >= 1.0 || relayManager.importStatusMessage.contains("Failed") || relayManager.importStatusMessage.contains("Complete") {
                            Button(action: {
                                relayManager.dismissImport()
                            }) {
                                Text("Close")
                                    .font(.appSystem(size: 14, weight: .bold))
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(Color.havenPurple)
                                    .cornerRadius(8)
                            }
                            .buttonStyle(.plain)
                            .frame(width: 200)
                        } else {
                            Button(action: {
                                relayManager.cancelImport()
                            }) {
                                Text("Cancel Import")
                                    .font(.appSystem(size: 13))
                                    .foregroundColor(.red)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .background(Color.red.opacity(0.1))
                                    .cornerRadius(8)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(24)
                    .background(Color.platformControlBackground)
                    .cornerRadius(12)
                    .shadow(color: Color.black.opacity(0.3), radius: 20)
                }
                .transition(.opacity)
            }

            // MARK: - Critical Process Kill Alert Overlay
            if relayManager.showProcessKillAlert {
                Color.black
                    .ignoresSafeArea()

                VStack(spacing: 20) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.appSystem(size: 48))
                        .foregroundColor(.orange)

                    VStack(spacing: 6) {
                        Text("Startup Error")
                            .font(.appTitle2.bold())
                            .foregroundColor(.white)

                        Text("A previous Nostr Vault process is still running. Run the following command in Terminal to stop it, then relaunch the app.")
                            .multilineTextAlignment(.center)
                            .foregroundColor(.white.opacity(0.9))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 8) {
                        Text("pkill -9 haven")
                            .font(.appSystem(size: 14, weight: .medium, design: .monospaced))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity)
                            .background(Color.white.opacity(0.1))
                            .cornerRadius(6)

                        Button(action: {
                            #if os(macOS)
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("pkill -9 haven", forType: .string)
                            #else
                            UIPasteboard.general.string = "pkill -9 haven"
                            #endif
                        }) {
                            Image(systemName: "doc.on.doc")
                                .font(.appSystem(size: 14))
                                .foregroundColor(.white)
                                .frame(width: 36, height: 36)
                                .background(Color.orange)
                                .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                        .help("Copy to clipboard")
                    }

                    Button(action: {
                        relayManager.showProcessKillAlert = false
                        relayManager.forceCleanAndRestart()
                    }) {
                        Text("Retry")
                            .font(.appHeadline)
                            .foregroundColor(.white)
                            .frame(width: 140, height: 36)
                            .background(Color.orange)
                            .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }
                .padding(30)
                .frame(width: 400)
                .background(Color.black)
                .cornerRadius(16)
                .transition(.scale.combined(with: .opacity))
                .zIndex(100)
            }
        }
        .overlay(alignment: .top) {
            VStack(spacing: 6) {
                PostActionNotificationBanner()
                ZapNotificationBanner()
                FollowNotificationBanner()
                ActionToastBanner()
                MediaUploadNotificationBanner()
                ErrorNotificationBanner()
            }
            .padding(.top, 4)
        }
        #if os(macOS)
        .sheet(isPresented: $showingCompose) {
            ComposeView(onDismiss: { showingCompose = false })
                .environmentObject(nostrService)
                .environmentObject(configService)
        }
        .onReceive(NotificationCenter.default.publisher(for: .composeFromTabBar)) { note in
            // SearchView owns object == 1 while it's on screen (selectedTab == .search);
            // for every other tab this is the only listener, so ⌘N works app-wide.
            guard (note.object as? Int) == 1, selectedTab != .search else { return }
            #if os(macOS)
            // Consume the flag too: the window was already open, so onAppear
            // will not run, and a flag left set would compose spuriously the
            // next time this view mounts.
            MacWindow.pendingCompose = false
            #endif
            showingCompose = true
        }
        .onAppear {
            FloatingArrowController.shared.dismiss()
            DMService.shared.startListening()
            #if os(macOS)
            // The status panel asks for a composer by setting this before the
            // window exists; this is the first moment a receiver could hear it.
            if MacWindow.consumePendingCompose() {
                showingCompose = true
            }
            #endif
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            // Service pausing moved to AppDelegate.startFocusLifecycleObservers().
            // This view is now mounted only by the window scene, so an app sitting
            // in the menu bar had no owner for it at all. Only the tab reset —
            // which is genuinely this view's concern — stays here.
            startInactivityTimer()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Service resuming moved to AppDelegate — see the resign handler above.
            stopInactivityTimer()
        }
        .onReceive(NotificationCenter.default.publisher(for: .havenOpenFeedRelaySettings)) { _ in
            selectedTab = .settings
        }
        .onReceive(NotificationCenter.default.publisher(for: .havenOpenSettings)) { _ in
            selectedTab = .settings
        }
        // MARK: - Keyboard Shortcuts
        .background {
            Group {
                Button("") { selectedTab = .feed }
                    .keyboardShortcut("1", modifiers: .command)
                Button("") { selectedTab = .search }
                    .keyboardShortcut("2", modifiers: .command)
                Button("") { selectedTab = .profile }
                    .keyboardShortcut("3", modifiers: .command)
                Button("") { selectedTab = .relay }
                    .keyboardShortcut("4", modifiers: .command)
                Button("") { selectedTab = .notes }
                    .keyboardShortcut("5", modifiers: .command)
                Button("") { selectedTab = .media }
                    .keyboardShortcut("6", modifiers: .command)
                // ⌘, opens the real Settings scene declared in HavenApp.swift.
                // It used to select the .settings tab instead, which left that
                // scene reachable from nothing in the entire app — `openSettings`
                // was declared here and never called. The status panel now does
                // the same thing, so the shortcut means one thing everywhere.
                //
                // The sidebar's embedded Settings tab is untouched and still
                // works; whether a window that hosts settings inline should also
                // have a separate Settings window is a design call, not mine.
                Button("") { openSettings() }
                    .keyboardShortcut(",", modifiers: .command)
                Button("") {
                    NotificationCenter.default.post(name: .composeFromTabBar, object: 1)
                }
                    .keyboardShortcut("n", modifiers: .command)
            }
            .frame(width: 0, height: 0)
            .opacity(0)
        }
        #endif
        .onReceive(ConfigService.shared.$activeAccountHexPubkey) { newHex in
            if activeHex != newHex {
                activeHex = newHex
            }
        }
    }
    
    private func startInactivityTimer() {
        inactivityTask?.cancel()
        inactivityTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            if !Task.isCancelled {
                selectedTab = .relay
            }
        }
    }

    private func stopInactivityTimer() {
        inactivityTask?.cancel()
        inactivityTask = nil
    }
}

struct SidebarTabButton: View {
    let icon: String
    let title: String
    let isSelected: Bool
    let action: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.appSystem(size: 15, weight: .semibold))
                    .foregroundColor(isSelected ? .white : (isHovered ? .primary : .secondary))
                    .frame(width: 20, height: 20)
                
                Text(title)
                    .font(.appSystem(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundColor(isSelected ? .white : (isHovered ? .primary : .secondary))
                
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.havenPurple : (isHovered ? Color.white.opacity(0.06) : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

struct TabButton: View {
    let icon: String
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.appSystem(size: 16, weight: isSelected ? .semibold : .medium))
                    .scaleEffect(isSelected ? 1.1 : 1.0)
                Text(title)
                    .font(.appSystem(size: 10, weight: isSelected ? .semibold : .regular))
            }
            .foregroundColor(isSelected ? Color.havenPurple : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - AccountSwitcherView

struct AccountSwitcherView: View {
    @ObservedObject var configService: ConfigService
    @ObservedObject private var nostrService = NostrService.shared
    @Environment(\.dismiss) private var dismiss

    // Key import sheet state
    @State private var importingNpub: String? = nil
    @State private var importNsec: String = ""
    @State private var importPassword: String = ""
    @State private var importConfirm: String = ""
    @State private var importError: String? = nil
    @State private var importSuccess: Bool = false

    private var activeNpub: String {
        let a = configService.config.activeAccountNpub.trimmingCharacters(in: .whitespacesAndNewlines)
        return a.isEmpty ? configService.config.ownerNpub : a
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Accounts")
                    .font(.appSystem(size: 13, weight: .semibold))
                    .foregroundColor(.primary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            // Account rows
            VStack(spacing: 2) {
                ForEach(configService.allAccountNpubs, id: \.self) { npub in
                    accountRow(npub: npub)
                }
            }
            .padding(.vertical, 6)
        }
        .frame(width: 270)
        .background(Color.platformControlBackground)
        .sheet(item: Binding<IdentifiableString?>(
            get: { importingNpub.map { IdentifiableString(id: $0) } },
            set: { importingNpub = $0?.id }
        )) { item in
            importKeySheet(forNpub: item.id)
        }
    }

    @ViewBuilder
    private func accountRow(npub: String) -> some View {
        let isOwner = npub == configService.config.ownerNpub
        let isActive = npub == activeNpub
        let hex = Bech32.decode(npub)?.hexString ?? ""
        let profile = nostrService.profiles[hex]
        let displayName = profile?.bestName ?? String(npub.prefix(16)) + "..."
        let hasKey = isOwner || configService.hasCredential(forNpub: npub)

        Button(action: {
            configService.switchActiveAccount(to: npub)
            dismiss()
        }) {
            HStack(spacing: 10) {
                // Avatar
                ZStack(alignment: .bottomTrailing) {
                    AvatarView(url: profile?.pictureURL, pubkey: hex)
                        .frame(width: 34, height: 34)
                        .overlay(
                            Circle()
                                .stroke(
                                    isActive
                                        ? (isOwner ? Color.havenPurple : Color.orange)
                                        : Color.clear,
                                    lineWidth: 2
                                )
                        )
                }

                // Name + badges
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(displayName)
                            .font(.appSystem(size: 13, weight: .semibold))
                            .foregroundColor(.primary)
                            .lineLimit(1)

                        if isOwner {
                            Text("Owner")
                                .font(.appSystem(size: 9, weight: .bold))
                                .foregroundColor(Color.havenPurple)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.havenPurple.opacity(0.15))
                                .cornerRadius(4)
                        }
                    }

                    Text(npub.prefix(20) + "...")
                        .font(.appSystem(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                // Key status / import
                if !hasKey {
                    Button(action: { importingNpub = npub }) {
                        Image(systemName: "key.fill")
                            .font(.appSystem(size: 11))
                            .foregroundColor(.orange)
                            .padding(6)
                            .background(Color.orange.opacity(0.12))
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .help("Import signing key")
                } else {
                    Image(systemName: "key.fill")
                        .font(.appSystem(size: 11))
                        .foregroundColor(.secondary.opacity(0.4))
                }

                // Active checkmark
                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                    .font(.appSystem(size: 15))
                    .foregroundColor(isActive ? Color.havenPurple : .secondary.opacity(0.3))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isActive ? Color.havenPurple.opacity(0.08) : Color.clear)
            .cornerRadius(8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
    }

    // MARK: - Import Key Sheet

    @ViewBuilder
    private func importKeySheet(forNpub npub: String) -> some View {
        let hex = Bech32.decode(npub)?.hexString ?? ""
        let profile = nostrService.profiles[hex]
        let displayName = profile?.bestName ?? String(npub.prefix(20)) + "..."

        VStack(spacing: 0) {
            // Sheet header
            HStack {
                AvatarView(url: profile?.pictureURL, pubkey: hex)
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Import Key")
                        .font(.appHeadline)
                    Text(displayName)
                        .font(.appCaption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding()

            Divider()

            Form {
                Section("Private Key") {
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $importNsec)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 70)
                            .padding(4)
                            .background(Color.platformControlBackground)
                            .cornerRadius(6)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                        if importNsec.isEmpty {
                            Text("nsec1...")
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.secondary.opacity(0.5))
                                .padding(8)
                                .allowsHitTesting(false)
                        }
                    }
                    Text("Enter the nsec for \(displayName)")
                        .font(.appCaption2)
                        .foregroundColor(.secondary)
                }

                Section("Encrypt with Password (NIP-49)") {
                    // Hidden username field anchors AutoFill to the npub so the
                    // nsec text editor above is not captured as the username.
                    TextField("", text: .constant(npub))
                        .textContentType(.username)
                        .frame(width: 0, height: 0)
                        .opacity(0)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    SecureField("Password", text: $importPassword)
                        .textContentType(.newPassword)
                    SecureField("Confirm Password", text: $importConfirm)
                        .textContentType(.newPassword)
                    Label("Password saved to Keychain automatically", systemImage: "lock.fill")
                        .font(.appCaption)
                        .foregroundColor(.green)
                }

                if let error = importError {
                    Section {
                        Text(error).font(.appCaption).foregroundColor(.red)
                    }
                }
                if importSuccess {
                    Section {
                        HStack {
                            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                            Text("Key imported successfully!").font(.appCaption).fontWeight(.semibold)
                        }
                    }
                }
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel") {
                    resetImportForm()
                    importingNpub = nil
                }
                .keyboardShortcut(.cancelAction)

                Button("Import") {
                    saveImportedKey(forNpub: npub)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(importNsec.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || importPassword.isEmpty)
            }
            .padding()
        }
        .frame(width: 420, height: 480)
    }

    private func saveImportedKey(forNpub npub: String) {
        let nsecTrimmed = importNsec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nsecTrimmed.isEmpty else { importError = "Private key cannot be empty"; return }
        guard importPassword == importConfirm else { importError = "Passwords do not match"; return }
        guard importPassword.count >= 8 else { importError = "Password must be at least 8 characters"; return }

        do {
            try configService.setCredential(nsec: nsecTrimmed, password: importPassword, forNpub: npub)
            importSuccess = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                resetImportForm()
                importingNpub = nil
            }
        } catch {
            importError = "Failed to encrypt key: \(error.localizedDescription)"
        }
    }

    private func resetImportForm() {
        importNsec = ""
        importPassword = ""
        importConfirm = ""
        importError = nil
        importSuccess = false
    }
}
