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
    #endif
    var isPoppedOut: Bool = false
    
    @ObservedObject private var nostrService = NostrService.shared
    @State private var inactivityTask: Task<Void, Never>?
    @State private var statusPulse = false
    @State private var showingOwnProfile = false
    @State private var showingAccountSwitcher = false
    
    private var activeHex: String {
        configService.activeAccountHexPubkey
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
        case profile
        case relay
        case settings
    }
    
    var body: some View {
        ZStack {
            Group {
                if isPoppedOut {
                    // MARK: - Premium Desktop Sidebar Layout
                    HStack(spacing: 0) {
                        // LEFT SIDEBAR
                        VStack(alignment: .leading, spacing: 0) {
                            // Brand Header
                            HStack(spacing: 10) {
                                Image(systemName: "server.rack")
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundColor(.havenPurple)
                                Text("Nostr Vault")
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundColor(.white)
                                Spacer()
                                
                                // Live status dot
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(relayManager.isBooting ? Color.yellow : (relayManager.isRunning ? Color.green : Color.red))
                                        .frame(width: 8, height: 8)
                                    Text(relayManager.isBooting ? "Booting" : (relayManager.isRunning ? "Online" : "Offline"))
                                        .font(.system(size: 10, weight: .semibold))
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
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundColor(.white)
                                            .lineLimit(1)
                                        Text(isOwner ? "Owner Key" : "Whitelisted")
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                    }
                                    
                                    Spacer()
                                    
                                    if hasMultipleAccounts {
                                        Image(systemName: "chevron.up.chevron.down")
                                            .font(.system(size: 10))
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
                            
                            // Sidebar Tabs
                            VStack(spacing: 4) {
                                SidebarTabButton(icon: "list.bullet.rectangle.portrait", title: "Feed", isSelected: selectedTab == .feed) {
                                    selectedTab = .feed
                                }
                                
                                SidebarTabButton(icon: "magnifyingglass", title: "Search", isSelected: selectedTab == .search) {
                                    selectedTab = .search
                                }
                                
                                SidebarTabButton(icon: "person.crop.circle", title: "My Profile", isSelected: selectedTab == .profile) {
                                    selectedTab = .profile
                                }
                                
                                SidebarTabButton(icon: "doc.text.image", title: "Relay", isSelected: selectedTab == .relay) {
                                    selectedTab = .relay
                                }
                                
                                SidebarTabButton(icon: "gearshape.fill", title: "Settings", isSelected: selectedTab == .settings) {
                                    selectedTab = .settings
                                }
                            }
                            .padding(.horizontal, 8)
                            
                            Spacer()
                            
                            // Quick start/stop relay action inside sidebar footer
                            VStack(spacing: 8) {
                                Button(action: {
                                    if relayManager.isRunning {
                                        relayManager.stopRelay()
                                    } else {
                                        relayManager.startRelay(config: configService.config)
                                    }
                                }) {
                                    HStack {
                                        Image(systemName: relayManager.isRunning ? "stop.circle.fill" : "play.circle.fill")
                                            .foregroundColor(relayManager.isRunning ? .red : .green)
                                        Text(relayManager.isBooting ? "Booting..." : (relayManager.isRunning ? "Stop Relay" : "Start Relay"))
                                            .font(.system(size: 13, weight: .semibold))
                                        Spacer()
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(relayManager.isRunning ? Color.red.opacity(0.1) : Color.green.opacity(0.1))
                                    .cornerRadius(8)
                                }
                                .buttonStyle(.plain)
                                .disabled(relayManager.isBooting)
                                
                                Button("Quit Nostr Vault") {
                                    #if os(macOS)
                                    NSApp.terminate(nil)
                                    #endif
                                }
                                .buttonStyle(.plain)
                                .foregroundColor(.secondary)
                                .font(.system(size: 12))
                                .padding(.top, 4)
                            }
                            .padding(16)
                        }
                        .frame(width: 220)
                        .background(Color(red: 0.1, green: 0.1, blue: 0.13))
                        
                        Divider()
                            .background(Color.platformSeparator)
                        
                        // MAIN CONTENT AREA
                        ZStack {
                            Color(red: 0.08, green: 0.08, blue: 0.1)
                                .ignoresSafeArea()
                            
                            switch selectedTab {
                            case .feed:
                                FeedView()
                                    .transition(.opacity)
                            case .search:
                                SearchView()
                                    .transition(.opacity)
                            case .profile:
                                ProfileView(pubkey: activeHex)
                                    .environmentObject(nostrService)
                                    .environmentObject(configService)
                                    .transition(.opacity)
                            case .relay:
                                ViewerView()
                                    .environmentObject(relayManager)
                                    .environmentObject(configService)
                                    .environmentObject(nostrService)
                                    .environmentObject(StatsService.shared)
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
                        .animation(.easeInOut(duration: 0.15), value: selectedTab)
                    }
                } else {
                    // Original Narrow Layout (Menu Bar dropdown)
                    VStack(spacing: 0) {
                        // MARK: - Header
                        HStack {
                            Label("Nostr Vault", systemImage: "server.rack")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.havenPurple)
                            
                            Spacer()
                            
                            if relayManager.isBooting {
                                Text(relayManager.bootStatusMessage)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(.secondary)
                                    .transition(.opacity)
                            }
                            
                            HStack(spacing: 6) {
                                // Power toggle icon button
                                Button(action: {
                                    if relayManager.isRunning {
                                        relayManager.stopRelay()
                                    } else {
                                        relayManager.startRelay(config: configService.config)
                                    }
                                }) {
                                    Image(systemName: relayManager.isRunning ? "stop.circle" : "play.circle")
                                        .font(.system(size: 16, weight: .medium))
                                        .foregroundColor(relayManager.isBooting ? .orange : (relayManager.isRunning ? .red.opacity(0.8) : .secondary))
                                        .frame(width: 28, height: 28)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(relayManager.isBooting)
                                .help(relayManager.isBooting ? "Booting..." : (relayManager.isRunning ? "Stop Relay" : "Start Relay"))

                                // Signal icon → relay dashboard
                                Button(action: {
                                    selectedTab = .relay
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                        NotificationCenter.default.post(name: NSNotification.Name("OpenRelayDashboard"), object: nil)
                                    }
                                }) {
                                    ZStack(alignment: .topTrailing) {
                                        Image(systemName: "antenna.radiowaves.left.and.right")
                                            .font(.system(size: 15, weight: .medium))
                                            .foregroundColor(
                                                relayManager.isBooting ? .orange :
                                                (relayManager.isRunning ? Color(red: 0.2, green: 0.85, blue: 0.5) : .secondary)
                                            )
                                            .scaleEffect(relayManager.isRunning && !relayManager.isBooting && statusPulse ? 1.08 : 1.0)
                                            .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: statusPulse)
                                            .onAppear { statusPulse = true }
                                            .onChange(of: relayManager.isRunning) { _, running in statusPulse = running }

                                        // Tiny status dot overlay
                                        Circle()
                                            .fill(relayManager.isBooting ? Color.orange : (relayManager.isRunning ? Color(red: 0.2, green: 0.85, blue: 0.5) : Color.red))
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
                                FeedView()
                                    .transition(.opacity)
                            case .search:
                                SearchView()
                                    .transition(.opacity)
                            case .profile:
                                ProfileView(pubkey: activeHex)
                                    .environmentObject(nostrService)
                                    .environmentObject(configService)
                                    .transition(.opacity)
                            case .relay:
                                ViewerView()
                                    .environmentObject(relayManager)
                                    .environmentObject(configService)
                                    .environmentObject(nostrService)
                                    .environmentObject(StatsService.shared)
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
                        .animation(.easeInOut(duration: 0.2), value: selectedTab)

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

                                TabButton(icon: "person.crop.circle", title: "Profile", isSelected: selectedTab == .profile) {
                                    selectedTab = .profile
                                }

                                TabButton(icon: "doc.text.image", title: "Relay", isSelected: selectedTab == .relay) {
                                    selectedTab = .relay
                                }

                                TabButton(icon: "gearshape.fill", title: "Settings", isSelected: selectedTab == .settings) {
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
                            
                            if !isPoppedOut {
                                Button(action: {
                                    #if os(macOS)
                                    openWindow(id: "viewer-window")
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                        NSApp.activate(ignoringOtherApps: true)
                                        for window in NSApp.windows {
                                            if window.title == "Nostr Vault" {
                                                window.makeKeyAndOrderFront(nil)
                                                window.level = .normal
                                            }
                                            
                                            if window.level.rawValue > NSWindow.Level.normal.rawValue && window.title.isEmpty {
                                                window.orderOut(nil)
                                            }
                                        }
                                    }
                                    #endif
                                }) {
                                    Image(systemName: "arrow.up.forward.square")
                                        .font(.system(size: 16))
                                        .foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Pop Out")
                            }
                            
                            Spacer()
                            
                            Button("Quit Nostr Vault") {
                                #if os(macOS)
                                NSApp.terminate(nil)
                                #endif
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(.secondary)
                            .font(.system(size: 13))
                        }
                        .padding()
                        .background(Color.platformControlBackground)
                    }
                }
            }
            .disabled(relayManager.isImporting) // Disable interaction when importing
            .onChange(of: configService.config.activeAccountNpub) { _, _ in
                // Force feed service to reload with the new account's perspective
                feedService.switchMode(feedService.feedMode)
            }

            // MARK: - Import Overlay
            if relayManager.isImporting {
                ZStack {
                    Color.black.opacity(0.8)
                        .ignoresSafeArea()
                    
                    VStack(spacing: 24) {
                        Text("Importing Notes")
                            .font(.title2.bold())
                            .foregroundColor(.white)
                        
                        // Progress Bar Custom Style
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(relayManager.importStatusMessage)
                                    .font(.caption)
                                    .foregroundColor(.white.opacity(0.8))
                                Spacer()
                                Text("\(Int(relayManager.importProgress * 100))%")
                                    .font(.caption.monospaced())
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
                            .font(.footnote)
                            .foregroundColor(.white.opacity(0.5))
                        
                        Divider()
                            .background(Color.white.opacity(0.2))
                        
                        if relayManager.importProgress >= 1.0 || relayManager.importStatusMessage.contains("Failed") || relayManager.importStatusMessage.contains("Complete") {
                            Button(action: {
                                relayManager.dismissImport()
                            }) {
                                Text("Close")
                                    .font(.system(size: 14, weight: .bold))
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
                                    .font(.system(size: 13))
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
                        .font(.system(size: 48))
                        .foregroundColor(.orange)

                    VStack(spacing: 6) {
                        Text("Startup Error")
                            .font(.title2.bold())
                            .foregroundColor(.white)

                        Text("A previous Nostr Vault process is still running. Run the following command in Terminal to stop it, then relaunch the app.")
                            .multilineTextAlignment(.center)
                            .foregroundColor(.white.opacity(0.9))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 8) {
                        Text("pkill -9 haven")
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
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
                                .font(.system(size: 14))
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
                            .font(.headline)
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
                ZapNotificationBanner()
                FollowNotificationBanner()
                MediaUploadNotificationBanner()
            }
            .padding(.top, 4)
        }
        #if os(macOS)
        .onAppear {
            FloatingArrowController.shared.dismiss()
            DMService.shared.startListening()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            startInactivityTimer()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            stopInactivityTimer()
        }
        #endif


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
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(isSelected ? .white : (isHovered ? .primary : .secondary))
                    .frame(width: 20, height: 20)
                
                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
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
                    .font(.system(size: 16, weight: isSelected ? .semibold : .medium))
                    .scaleEffect(isSelected ? 1.1 : 1.0)
                Text(title)
                    .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
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
                    .font(.system(size: 13, weight: .semibold))
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
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.primary)
                            .lineLimit(1)

                        if isOwner {
                            Text("Owner")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(Color.havenPurple)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.havenPurple.opacity(0.15))
                                .cornerRadius(4)
                        }
                    }

                    Text(npub.prefix(20) + "...")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                // Key status / import
                if !hasKey {
                    Button(action: { importingNpub = npub }) {
                        Image(systemName: "key.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.orange)
                            .padding(6)
                            .background(Color.orange.opacity(0.12))
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .help("Import signing key")
                } else {
                    Image(systemName: "key.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary.opacity(0.4))
                }

                // Active checkmark
                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
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
                        .font(.headline)
                    Text(displayName)
                        .font(.caption)
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
                        .font(.caption2)
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
                        .font(.caption)
                        .foregroundColor(.green)
                }

                if let error = importError {
                    Section {
                        Text(error).font(.caption).foregroundColor(.red)
                    }
                }
                if importSuccess {
                    Section {
                        HStack {
                            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                            Text("Key imported successfully!").font(.caption).fontWeight(.semibold)
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

// MARK: - SearchView

struct SearchView: View {
    @StateObject private var feedService = FeedService.shared
    @EnvironmentObject var relayManager: RelayProcessManager
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var nostrService: NostrService

    @State private var searchQuery: String = ""
    @State private var searchSource: SearchSource = .all
    @State private var searchResults: SearchResults = .empty
    @State private var isSearching = false
    @State private var showingNoteDetail: FeedNote?
    @State private var showingProfile: String?
    @State private var showingMediaUrl: IdentifiableURL?
    @State private var pendingDirectNoteId: String?
    #if os(iOS)
    @FocusState private var searchFieldFocused: Bool
    #endif

    enum SearchSource {
        case all
        case havenRelay
        case network

        var label: String {
            switch self {
            case .all: return "All"
            case .havenRelay: return "Nostr Vault Relay"
            case .network: return "Network"
            }
        }
    }

    struct SearchResults {
        var users: [String: FeedProfile] = [:]
        var notes: [FeedNote] = []
        var links: [SearchLink] = []
        var hashtags: [String] = []

        static let empty = SearchResults()

        var isEmpty: Bool {
            users.isEmpty && notes.isEmpty && links.isEmpty && hashtags.isEmpty
        }
    }

    struct SearchLink {
        let url: String
        let title: String
        let noteId: String
    }

    var body: some View {
        ZStack {
            Color(red: 0.08, green: 0.08, blue: 0.1).ignoresSafeArea()

            VStack(spacing: 0) {
                // Search header
                VStack(spacing: 12) {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.secondary)

                        TextField("Search users, notes, hashtags...", text: $searchQuery)
                            .textFieldStyle(.plain)
                            .font(.system(size: 14))
                            #if os(iOS)
                            .focused($searchFieldFocused)
                            .submitLabel(.search)
                            .onSubmit { searchFieldFocused = false }
                            #endif
                            .onChange(of: searchQuery) { _, query in
                                performSearch(query: query)
                            }

                        if !searchQuery.isEmpty {
                            Button(action: {
                                searchQuery = ""
                                #if os(iOS)
                                searchFieldFocused = false
                                #endif
                            }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 14))
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(10)

                    // Source filter
                    HStack(spacing: 8) {
                        ForEach([SearchSource.all, .havenRelay, .network], id: \.self) { source in
                            Button(action: { searchSource = source }) {
                                Text(source.label)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(searchSource == source ? .white : .secondary)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(searchSource == source ? Color.havenPurple : Color.clear)
                                    .cornerRadius(6)
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 4)
                }
                .padding()
                .background(Color(red: 0.08, green: 0.08, blue: 0.1))

                Divider()

                // Results
                if searchQuery.isEmpty {
                    emptyState
                } else if isSearching {
                    loadingState
                } else if searchResults.isEmpty {
                    noResultsState
                } else {
                    resultsContent
                }
            }
        }
        #if os(iOS)
        .onTapGesture {
            searchFieldFocused = false
        }
        #endif
        .sheet(item: Binding<IdentifiableString?>(
            get: { showingProfile.map { IdentifiableString(id: $0) } },
            set: { showingProfile = $0?.id }
        )) { profile in
            ProfileView(pubkey: profile.id, onDismiss: { showingProfile = nil })
                .environmentObject(nostrService)
                .environmentObject(configService)
        }
        .sheet(item: $showingNoteDetail) { note in
            NavigationStack {
                NoteDetailView(note: note)
                    .navigationDestination(for: FeedNote.self) { detailNote in
                        NoteDetailView(note: detailNote)
                    }
            }
        }
        .sheet(item: $showingMediaUrl) { media in
            FeedMediaViewer(url: media.url, onDismiss: { showingMediaUrl = nil })
        }
        .onReceive(feedService.$notes) { notes in
            guard let noteId = pendingDirectNoteId else { return }
            if let note = notes.first(where: { $0.id == noteId }) {
                pendingDirectNoteId = nil
                isSearching = false
                showingNoteDetail = note
            }
        }
        .onReceive(feedService.$parentNotesCache) { cache in
            guard let noteId = pendingDirectNoteId else { return }
            if let note = cache[noteId] {
                pendingDirectNoteId = nil
                isSearching = false
                showingNoteDetail = note
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 24) {
            VStack(spacing: 16) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 48, weight: .thin))
                    .foregroundColor(.secondary.opacity(0.5))

                VStack(spacing: 8) {
                    Text("Start Searching")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.primary)
                    Text("Search for users, notes, hashtags and links\nOr paste a note1 or nevent1 to jump directly to a note")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    @ViewBuilder
    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
                .tint(Color.havenPurple)
            if pendingDirectNoteId != nil {
                Text("Looking up note...")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var noResultsState: some View {
        VStack(spacing: 16) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 32, weight: .thin))
                .foregroundColor(.secondary.opacity(0.5))

            Text("No results found")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    @ViewBuilder
    private var resultsContent: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Users section
                if !searchResults.users.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Users")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 16)

                        VStack(spacing: 8) {
                            ForEach(searchResults.users.sorted(by: { $0.key < $1.key }), id: \.key) { pubkey, profile in
                                userRow(pubkey: pubkey, profile: profile)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }

                // Notes section
                if !searchResults.notes.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Notes")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 16)

                        VStack(spacing: 8) {
                            ForEach(searchResults.notes) { note in
                                FeedNoteRow(
                                   note: note,
                                   profile: nostrService.profiles[note.pubkey],
                                   onProfile: { pubkey in
                                       showingProfile = pubkey
                                   },
                                   onMedia: { url in
                                       showingMediaUrl = IdentifiableURL(url: url)
                                   },
                                   showParent: false
                               )
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        showingNoteDetail = note
                                    }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }

                // Hashtags section
                if !searchResults.hashtags.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Hashtags")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 16)

                        VStack(spacing: 8) {
                            ForEach(searchResults.hashtags, id: \.self) { hashtag in
                                hashtagRow(hashtag: hashtag)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }

                // Links section
                if !searchResults.links.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Links")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 16)

                        VStack(spacing: 8) {
                            ForEach(searchResults.links, id: \.url) { link in
                                linkRow(link: link)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }
            .padding(.vertical, 16)
            #if os(iOS)
            .padding(.bottom, 90)
            #endif
        }
    }

    @ViewBuilder
    private func userRow(pubkey: String, profile: FeedProfile) -> some View {
        Button(action: { showingProfile = pubkey }) {
            HStack(spacing: 12) {
                AvatarView(url: profile.pictureURL, pubkey: pubkey)
                    .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.bestName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    Text(pubkey.prefix(16) + "...")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary.opacity(0.5))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.secondary.opacity(0.05))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func hashtagRow(hashtag: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("#\(hashtag)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.havenPurple)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary.opacity(0.5))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(8)
    }

    @ViewBuilder
    private func linkRow(link: SearchLink) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(link.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.havenPurple)
                .lineLimit(1)

            Text(link.url)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(8)
    }

    private func decodeNostrNoteId(_ query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let result = Bech32.decode(trimmed) else { return nil }
        if result.hrp == "note" {
            return result.data.count == 32 ? result.hexString : nil
        } else if result.hrp == "nevent" {
            var offset = 0
            let data = result.data
            while offset + 1 < data.count {
                let type = data[offset]
                let length = Int(data[offset + 1])
                offset += 2
                guard offset + length <= data.count else { break }
                if type == 0 && length == 32 {
                    return data[offset..<(offset + length)].map { String(format: "%02x", $0) }.joined()
                }
                offset += length
            }
        }
        return nil
    }

    private func performSearch(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = .empty
            pendingDirectNoteId = nil
            return
        }

        let lower = trimmed.lowercased()
        if lower.hasPrefix("note1") || lower.hasPrefix("nevent1") {
            if let eventId = decodeNostrNoteId(trimmed) {
                if let note = feedService.findNote(id: eventId) {
                    showingNoteDetail = note
                } else {
                    pendingDirectNoteId = eventId
                    isSearching = true
                    searchResults = .empty
                    feedService.fetchMissingNote(id: eventId)
                }
            }
            return
        }

        pendingDirectNoteId = nil
        isSearching = true
        let trimmedQuery = query.lowercased().trimmingCharacters(in: .whitespaces)

        let localProfiles = nostrService.profiles
        let localNotes = feedService.notes

        DispatchQueue.global(qos: .userInitiated).async {
            var results = SearchResults()

            for (pubkey, profile) in localProfiles {
                if profile.bestName.lowercased().contains(trimmedQuery) ||
                   pubkey.lowercased().contains(trimmedQuery) ||
                   (profile.about?.lowercased().contains(trimmedQuery) ?? false) {
                    results.users[pubkey] = profile
                }
            }

            let relevantNotes = localNotes.filter { note in
                note.content.lowercased().contains(trimmedQuery)
            }
            results.notes = relevantNotes.prefix(20).map { $0 }

            var foundHashtags = Set<String>()
            for note in relevantNotes {
                let hashtags = extractHashtags(from: note.content)
                for tag in hashtags {
                    if tag.lowercased().contains(trimmedQuery) {
                        foundHashtags.insert(tag)
                    }
                }
            }
            results.hashtags = Array(foundHashtags).sorted()

            let urls = extractURLs(from: relevantNotes)
            results.links = urls.filter { $0.url.lowercased().contains(trimmedQuery) ||
                                          $0.title.lowercased().contains(trimmedQuery) }

            DispatchQueue.main.async {
                self.searchResults = results
                self.isSearching = false
            }
        }
    }

    private func extractHashtags(from text: String) -> [String] {
        let pattern = "#\\w+"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        return matches.compactMap {
            guard let range = Range($0.range, in: text) else { return nil }
            return String(text[range]).dropFirst().lowercased()
        }
    }

    private func extractURLs(from notes: [FeedNote]) -> [SearchLink] {
        var links: [SearchLink] = []
        let urlPattern = "https?://[^\\s]+"

        guard let regex = try? NSRegularExpression(pattern: urlPattern) else { return [] }

        for note in notes {
            let matches = regex.matches(in: note.content, range: NSRange(note.content.startIndex..., in: note.content))
            for match in matches {
                guard let range = Range(match.range, in: note.content) else { continue }
                let url = String(note.content[range])
                links.append(SearchLink(url: url, title: url.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: ""), noteId: note.id))
            }
        }

        return links
    }
}
