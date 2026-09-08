import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import UniformTypeIdentifiers
import LocalAuthentication

extension NumberFormatter {
    static var noSeparator: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.usesGroupingSeparator = false
        return formatter
    }
}

struct SettingsView: View {
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var relayManager: RelayProcessManager
    @State private var selectedTab: SettingsTab = .accounts
    @State private var saveTask: Task<Void, Never>?
    @State private var isRestarting = false
    @State private var showingSetupWizard = false
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif
    var isEmbedded: Bool = false
    
    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.3.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        #if os(macOS)
        return "\(version)" // macOS hasn't traditionally shown build number in this particular ui
        #else
        return "\(version) (\(build))"
        #endif
    }
    
    var needsRestart: Bool {
        guard let lastLaunch = relayManager.lastConfig else { return false }
        var current = configService.config
        let last = lastLaunch
        current.activeAccountNpub = last.activeAccountNpub
        return current != last
    }
    
    enum SettingsTab: String, CaseIterable, Identifiable {
        case accounts = "Accounts"
        case blocked = "Blocked"
        case appearance = "Appearance"
        case feed = "Feed Relays"
        case dm = "DM Relays"
        case pushNotifications = "Notifications"
        case importNotes = "Import"
        case backup = "Backup"
        case followingBackup = "Following Backup"
        case blastr = "Blastr"
        case blossom = "Blossom"
        case macRelay = "Mac Relay"
        case proofOfWork = "Proof of Work"
        case advanced = "Advanced"
        case wallet = "Wallet"
        case logs = "Logs"

        var id: String { self.rawValue }

        var title: String {
            switch self {
            case .macRelay:
                #if os(macOS)
                return "Domain"
                #else
                return rawValue
                #endif
            default:
                return rawValue
            }
        }

        var icon: String {
            switch self {
            case .accounts: return "person.badge.key"
            case .blocked: return "person.crop.circle.badge.xmark"
            case .appearance: return "paintpalette"
            case .feed: return "newspaper"
            case .dm: return "bubble.left.and.bubble.right"
            case .pushNotifications: return "bell.badge"
            case .importNotes: return "square.and.arrow.down"
            case .backup: return "externaldrive.fill"
            case .followingBackup: return "person.crop.circle.badge.clock"
            case .blastr: return "paperplane"
            case .blossom: return "server.rack"
            case .macRelay:
                #if os(macOS)
                return "globe"
                #else
                return "desktopcomputer"
                #endif
            case .proofOfWork: return "hammer.fill"
            case .advanced: return "gearshape.2"
            case .wallet: return "bitcoinsign.circle"
            case .logs: return "list.bullet.rectangle"
            }
        }
    }
    
    var body: some View {
        Group {
            #if os(iOS)
            iOSBody
            #else
            macOSBody
            #endif
        }
        .onChange(of: configService.config) { _, _ in
            saveTask?.cancel()
            saveTask = Task {
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second debounce
                if !Task.isCancelled {
                    configService.save()
                }
            }
        }
        .onDisappear {
            saveTask?.cancel()
        }
        #if os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: .havenOpenFeedRelaySettings)) { _ in
            selectedTab = .feed
        }
        #endif
    }

    private var macOSBody: some View {
        HStack(spacing: 0) {
            settingsSidebar
            
            Divider()
                .background(Color.platformSeparator)
            
            // CONTENT VIEW DETAIL PANEL
            ZStack {
                Color.platformWindowBackground
                    .ignoresSafeArea()
                
                VStack(alignment: .leading, spacing: 0) {
                    // Header of active settings panel
                    HStack {
                        Text(selectedTab.title)
                            .font(.appTitle2.bold())
                            .foregroundColor(.white)
                        Spacer()
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                    
                    Divider()
                        .background(Color.platformSeparator)
                    
                    ScrollView {
                        destinationFor(selectedTab)
                            .environmentObject(configService)
                            .environmentObject(relayManager)
                            .padding(24)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: isEmbedded ? .infinity : 900, maxHeight: isEmbedded ? .infinity : 650)
    }

    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header inside settings sidebar
            HStack(spacing: 8) {
                Image(systemName: "gearshape.fill")
                    .font(.appSystem(size: 16, weight: .bold))
                    .foregroundColor(.havenPurple)
                Text("Settings")
                    .font(.appSystem(size: 16, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
            
            Divider()
                .background(Color.platformSeparator)
                .padding(.bottom, 12)

            #if os(macOS)
            if !configService.config.hasCompletedSetup {
                Button(action: {
                    openWindow(id: "setup")
                    NSApp.activate(ignoringOtherApps: true)
                }) {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.appSystem(size: 14))
                            .foregroundColor(.yellow)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Setup Incomplete")
                                .font(.appSystem(size: 12, weight: .bold))
                                .foregroundColor(.white)
                            Text("Tap to complete setup")
                                .font(.appSystem(size: 10))
                                .foregroundColor(.white.opacity(0.7))
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.appSystem(size: 10, weight: .bold))
                            .foregroundColor(.white.opacity(0.5))
                    }
                    .padding(10)
                    .background(Color.orange.opacity(0.15))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            #endif

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    settingsSidebarSection("Profile", items: [.accounts, .blocked])
                    settingsSidebarSection("Appearance", items: [.appearance])
                    settingsSidebarSection("Relay Configuration", items: [.macRelay, .feed, .blastr, .blossom, .importNotes, .backup, .followingBackup])
                    settingsSidebarSection("System", items: [.pushNotifications, .wallet, .advanced, .logs])
                }
                .padding(.horizontal, 8)
            }
            
            Spacer()
            
            Divider()
                .background(Color.platformSeparator)
            
            // Save & Restart / About in sidebar bottom
            VStack(spacing: 8) {
                if isRestarting {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.vertical, 8)
                } else {
                    Button(action: restartRelay) {
                        Text("Save & Restart Relay")
                            .font(.appSystem(size: 11, weight: .bold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color.havenPurple)
                            .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                    .disabled((!needsRestart && configService.config == relayManager.lastConfig) || !relayManager.isRunning)
                }
                
                VStack(spacing: 2) {
                    Text("Nostr Vault v\(appVersion)")
                        .font(.appSystem(size: 9, weight: .bold))
                        .foregroundColor(.secondary)
                    Text("Abuse Reporting: npub1vxlh...g0nvx")
                        .font(.appSystem(size: 8, design: .monospaced))
                        .foregroundColor(.secondary.opacity(0.8))
                        .onTapGesture {
                            PlatformClipboard.copy("npub1vxlhjzeqjjhmqdy4e8sndt8kzklqlnxzew2mtt8mtakvalsckp3qa0gnvx")
                        }
                }
                .padding(.top, 4)
            }
            .padding(12)
            .background(Color.black.opacity(0.15))
        }
        .frame(width: 220)
        .background(Color(red: 0.1, green: 0.1, blue: 0.13))
    }
    
    private func settingsSidebarSection(_ title: String, items: [SettingsTab]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.appSystem(size: 9, weight: .bold))
                .foregroundColor(.secondary.opacity(0.7))
                .padding(.horizontal, 8)
                .padding(.bottom, 2)
            
            ForEach(items) { item in
                Button(action: {
                    withAnimation(Motion.control) {
                        selectedTab = item
                    }
                }) {
                    HStack(spacing: 8) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(iconBackgroundColor(for: item))
                                .frame(width: 20, height: 20)
                            Image(systemName: item.icon)
                                .font(.appSystem(size: 11, weight: .semibold))
                                .foregroundColor(.white)
                        }
                        
                        Text(item.title)
                            .font(.appSystem(size: 12, weight: selectedTab == item ? .semibold : .medium))
                            .foregroundColor(selectedTab == item ? .white : .secondary)
                        
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(selectedTab == item ? Color.havenPurple.opacity(0.15) : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(selectedTab == item ? Color.havenPurple.opacity(0.3) : Color.clear, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 8)
    }
    
    #if os(iOS)
    private var iOSBody: some View {
        List {
            if !configService.config.hasCompletedSetup {
                Section {
                    Button(action: { showingSetupWizard = true }) {
                        HStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.appTitle2)
                                .foregroundColor(.yellow)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Setup Incomplete")
                                    .font(.appHeadline)
                                    .foregroundColor(.white)
                                Text("Tap to complete setup and start your relay.")
                                    .font(.appCaption)
                                    .foregroundColor(.white.opacity(0.8))
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.appCaption.bold())
                                .foregroundColor(.white.opacity(0.5))
                        }
                        .padding()
                        .background(Color.orange.opacity(0.15))
                        .cornerRadius(12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            Section {
                if needsRestart && relayManager.isRunning {
                    RestartBanner(action: restartRelay, isRestarting: isRestarting)
                }
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)

            Section("Profile") {
                tabLink(.accounts)
                tabLink(.blocked)
            }
            
            Section("Appearance") {
                tabLink(.appearance)
            }
            
            Section("Relay Configuration") {
                tabLink(.feed)
                tabLink(.blastr)
                tabLink(.blossom)
                tabLink(.importNotes)
                tabLink(.backup)
                tabLink(.followingBackup)
                tabLink(.macRelay)
            }

            Section("System") {
                tabLink(.pushNotifications)
                tabLink(.wallet)
                tabLink(.advanced)
                tabLink(.logs)
            }
            
            Section("About") {
                VStack(spacing: 4) {
                    Text("Nostr Vault")
                        .font(.appHeadline)
                    Text("Version \(appVersion)")
                        .font(.appCaption)
                        .foregroundColor(.secondary)
                    
                    Divider()
                        .padding(.vertical, 8)
                    
                    VStack(spacing: 8) {
                        Text("Support & Abuse Reporting")
                            .font(.appSubheadline.bold())
                        
                        Text("To report objectionable content or abusive users, contact the developer via Nostr")
                            .font(.appCaption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        
                        Text("npub1vxlhjzeqjjhmqdy4e8sndt8kzklqlnxzew2mtt8mtakvalsckp3qa0gnvx")
                            .font(.appSystem(size: 10, design: .monospaced))
                            .padding(8)
                            .background(Color.platformControlBackground)
                            .cornerRadius(4)
                            .onTapGesture {
                                PlatformClipboard.copy("npub1vxlhjzeqjjhmqdy4e8sndt8kzklqlnxzew2mtt8mtakvalsckp3qa0gnvx")
                            }
                        
                        Text("(Tap to copy)")
                            .font(.appSystem(size: 8))
                            .foregroundColor(.secondary)
                            
                        Divider()
                            .padding(.vertical, 8)
                            
                        Link("Privacy Policy", destination: URL(string: "https://nostrvault.app/privacy.html")!)
                            .font(.appCaption)
                            .foregroundColor(.havenPurple)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .listRowBackground(Color.clear)

            // Spacer so the last section can scroll above the floating tab bar
            #if os(iOS)
            Section { EmptyView() }
                .listRowBackground(Color.clear)
                .frame(height: 60)
            #endif
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Settings")
        .sheet(isPresented: $showingSetupWizard) {
            SetupWizardView {
                relayManager.startRelay(config: configService.config)
            }
            .environmentObject(configService)
            .environmentObject(relayManager)
            .environmentObject(NostrService.shared)
            .environmentObject(StatsService.shared)
        }
    }
    #endif

    private func tabLink(_ tab: SettingsTab) -> some View {
        NavigationLink(destination: destinationFor(tab)) {
            Label {
                Text(tab.title)
                    .font(.appBody)
            } icon: {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(iconBackgroundColor(for: tab))
                        .frame(width: 28, height: 28)
                    Image(systemName: tab.icon)
                        .font(.appSystem(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                }
            }
        }
    }

    private func iconBackgroundColor(for tab: SettingsTab) -> Color {
        switch tab {
        case .accounts: return .blue
        case .blocked: return .red
        case .appearance: return .purple
        case .feed: return .pink
        case .dm: return .mint
        case .pushNotifications: return .blue
        case .importNotes: return .orange
        case .backup: return .indigo
        case .followingBackup: return .teal
        case .blastr: return .cyan
        // Stays system green: this list is a categorical palette for the
        // section icons (pink, mint, blue, indigo, teal…), not a status. Using
        // `havenOnline` here would give one settings row the vocabulary of a
        // health indicator.
        case .blossom: return .green
        case .macRelay: return .teal
        case .proofOfWork: return .purple
        case .advanced: return .gray
        case .wallet: return .orange
        case .logs: return .secondary
        }
    }

    private func restartRelay() {
        isRestarting = true
        configService.save()
        relayManager.stopRelay {
            Task { @MainActor in
                relayManager.startRelay(config: configService.config)
                isRestarting = false
            }
        }
    }
    
    @ViewBuilder
    private func destinationFor(_ tab: SettingsTab) -> some View {
        Group {
            switch tab {
            case .accounts: AccountsSettingsView()
            case .blocked: BlockedSettingsView()
            case .appearance: AppearanceSettingsView()
            case .feed: FeedSettingsView()
            case .dm: DMSettingsView()
            case .pushNotifications: PushNotificationSettingsView()
            case .importNotes: ImportSettingsView()
            case .backup: BackupSettingsView()
            case .followingBackup: FollowingBackupSettingsView()
            case .blastr: BlastrSettingsView()
            case .blossom: BlossomSettingsView()
            case .macRelay:
                #if os(iOS)
                MacRelaySettingsView()
                #else
                MacRelayDomainSettingsView()
                #endif
            case .proofOfWork: ProofOfWorkSettingsView()
            case .advanced: AdvancedSettingsView()
            case .wallet: WalletSettingsView()
            case .logs: LogsView(logStore: relayManager.logStore)
            }
        }
        .navigationTitle(tab.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
    
    private var footer: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                if isRestarting {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button(action: restartRelay) {
                        Text("Save & Restart Relay")
                            .font(.appHeadline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.havenPurple)
                            .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                    .disabled((!needsRestart && configService.config == relayManager.lastConfig) || !relayManager.isRunning)
                }
            }
            .padding()
            #if os(macOS)
            .background(.ultraThinMaterial)
            #endif
            
            Divider()
            
            // About Section for macOS
            VStack(spacing: 4) {
                Text("Nostr Vault v\(appVersion)")
                    .font(.appCaption.bold())
                Text("Abuse Reporting: npub1vxlh...g0nvx")
                    .font(.appSystem(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
                    .onTapGesture {
                        PlatformClipboard.copy("npub1vxlhjzeqjjhmqdy4e8sndt8kzklqlnxzew2mtt8mtakvalsckp3qa0gnvx")
                    }
                Link("Privacy Policy", destination: URL(string: "https://nostrvault.app/privacy.html")!)
                    .font(.appSystem(size: 10))
                    .foregroundColor(.havenPurple)
                    .padding(.top, 2)
            }
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity)
        }
    }
}

struct RestartBanner: View {
    var action: () -> Void
    var isRestarting: Bool
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .font(.appTitle2)
                    .foregroundColor(.white)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Restart Required")
                        .font(.appHeadline)
                        .foregroundColor(.white)
                    Text("Some changes require a relay restart to take effect.")
                        .font(.appCaption)
                        .foregroundColor(.white.opacity(0.8))
                }
                
                Spacer()
                
                if isRestarting {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.appCaption.bold())
                        .foregroundColor(.white.opacity(0.5))
                }
            }
            .padding()
            .background(Color.havenPurple)
            .cornerRadius(12)
            .padding(.horizontal)
        }
        .buttonStyle(.plain)
        .disabled(isRestarting)
    }
}


struct AccountsSettingsView: View {
    @EnvironmentObject var configService: ConfigService
    @ObservedObject private var nostrService = NostrService.shared
    @ObservedObject private var nip46Service = NIP46Service.shared

    // Add Account Sheet
    @State private var showAddAccount = false

    // Account Detail Sheet
    @State private var selectedAccountNpub: String? = nil

    // Import Key Sheet
    @State private var importingNpub: String? = nil

    // Reveal Key Sheet
    @State private var revealingNpub: String? = nil

    // Connect Signer Sheet
    @State private var connectingSignerNpub: String? = nil

    var body: some View {
        Form {
            Section {
                ForEach(configService.allAccountNpubs, id: \.self) { npub in
                    accountRow(npub: npub)
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        guard index > 0 else { continue }
                        let npub = configService.allAccountNpubs[index]
                        configService.config.whitelistedNpubs.removeAll { $0.trimmingCharacters(in: .whitespacesAndNewlines) == npub }
                        configService.removeBunkerConfig(forNpub: npub)
                        configService.removeCredential(forNpub: npub)
                        configService.config.accountSigningModes.removeValue(forKey: npub)
                        if configService.config.activeAccountNpub == npub {
                            configService.config.activeAccountNpub = ""
                            configService.refreshActiveAccountHex()
                        }
                    }
                    configService.save()
                }
            } header: {
                Text("Accounts")
            } footer: {
                Text("Each account can hold both a local key and a remote signer. Tap to manage signing. Swipe to remove.")
            }

            Section {
                Button(action: {
                    showAddAccount = true
                }) {
                    Label("Add Account", systemImage: "plus.circle.fill")
                }
            }
        }
        .groupedFormStyleCompat()
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(isPresented: $showAddAccount) {
            AddAccountSheetView(onDismiss: { showAddAccount = false }, configService: configService)
        }
        .sheet(item: Binding<IdentifiableString?>(
            get: { importingNpub.map { IdentifiableString(id: $0) } },
            set: { importingNpub = $0?.id }
        )) { item in
            ImportKeySheetView(onDismiss: { importingNpub = nil }, configService: configService, npub: item.id)
        }
        .sheet(item: Binding<IdentifiableString?>(
            get: { revealingNpub.map { IdentifiableString(id: $0) } },
            set: { revealingNpub = $0?.id }
        )) { item in
            RevealKeySheetView(onDismiss: { revealingNpub = nil }, configService: configService, npub: item.id)
        }
        .sheet(item: Binding<IdentifiableString?>(
            get: { connectingSignerNpub.map { IdentifiableString(id: $0) } },
            set: { connectingSignerNpub = $0?.id }
        )) { item in
            ConnectSignerSheetView(onDismiss: { connectingSignerNpub = nil }, configService: configService, npub: item.id)
        }
        .sheet(item: Binding<IdentifiableString?>(
            get: { selectedAccountNpub.map { IdentifiableString(id: $0) } },
            set: { selectedAccountNpub = $0?.id }
        )) { item in
            AccountDetailView(
                configService: configService,
                npub: item.id,
                onImportKey: {
                    selectedAccountNpub = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        importingNpub = item.id
                    }
                },
                onConnectBunker: {
                    selectedAccountNpub = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        connectingSignerNpub = item.id
                    }
                },
                onRevealKey: {
                    selectedAccountNpub = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        revealingNpub = item.id
                    }
                },
                onRemoveAccount: {
                    configService.config.whitelistedNpubs.removeAll { $0.trimmingCharacters(in: .whitespacesAndNewlines) == item.id }
                    configService.removeBunkerConfig(forNpub: item.id)
                    configService.removeCredential(forNpub: item.id)
                    configService.config.accountSigningModes.removeValue(forKey: item.id)
                    if configService.config.activeAccountNpub == item.id {
                        configService.config.activeAccountNpub = ""
                        configService.refreshActiveAccountHex()
                    }
                    configService.save()
                }
            )
        }
    }

    private func accountRow(npub: String) -> some View {
        let hex = Bech32.decode(npub)?.hexString ?? ""
        let profile = nostrService.profiles[hex]
        let displayName = profile?.bestName ?? String(npub.prefix(12)) + "..."
        let isOwner = (npub == configService.config.ownerNpub)
        let activeNpub = configService.config.activeAccountNpub.trimmingCharacters(in: .whitespacesAndNewlines)
        let isActive = activeNpub.isEmpty ? isOwner : npub == activeNpub
        let hasLocalKey = isOwner ? !configService.config.ownerNcryptsec.isEmpty : configService.hasCredential(forNpub: npub)
        let hasBunker = configService.hasBunkerConfig(forNpub: npub)
        let signingMode = configService.config.accountSigningModes[npub] ?? (hasBunker ? "nip46" : "local")

        return HStack(spacing: 12) {
            AvatarView(url: profile?.pictureURL, pubkey: hex)
                .frame(width: 38, height: 38)
                .overlay(
                    Circle().stroke(
                        isActive ? (isOwner ? Color.havenPurple : Color.orange) : Color.clear,
                        lineWidth: 2
                    )
                )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(displayName).fontWeight(.semibold)
                    if isOwner {
                        Text("Owner")
                            .font(.appSystem(size: 10, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.havenPurple.opacity(0.2))
                            .foregroundColor(.havenPurple)
                            .cornerRadius(4)
                    }
                }

                // Compact signing mode indicator
                HStack(spacing: 4) {
                    if hasBunker && signingMode == "nip46" {
                        Image(systemName: "link")
                            .font(.appSystem(size: 9))
                        Text("Remote Signer")
                        if isActive {
                            Circle()
                                .fill(nip46Service.isConnected ? Color.havenOnline : Color.red)
                                .frame(width: 5, height: 5)
                        }
                    } else if hasLocalKey {
                        Image(systemName: "key.fill")
                            .font(.appSystem(size: 9))
                            .foregroundColor(.orange)
                        Text("Local Key")
                    } else {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.appSystem(size: 9))
                        Text("No signing key")
                    }
                }
                .font(.appCaption)
                .foregroundColor(.secondary)
            }

            Spacer()

            if isActive {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.havenOnline)
            }

            Image(systemName: "chevron.right")
                .font(.appCaption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            selectedAccountNpub = npub
        }
    }
}

// MARK: - Account Detail View (Signing Management)

struct AccountDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var configService: ConfigService
    @ObservedObject private var nostrService = NostrService.shared
    @ObservedObject private var nip46Service = NIP46Service.shared
    let npub: String

    var onImportKey: () -> Void
    var onConnectBunker: () -> Void
    var onRevealKey: () -> Void
    var onRemoveAccount: () -> Void

    // Every account action below is one-way: the key material is gone, or the
    // signer link is, and nothing here can put it back.
    @State private var showingRemoveKeyConfirm = false
    @State private var showingDisconnectSignerConfirm = false
    @State private var showingRemoveAccountConfirm = false

    private var isOwner: Bool { npub == configService.config.ownerNpub }
    private var activeNpub: String {
        let a = configService.config.activeAccountNpub.trimmingCharacters(in: .whitespacesAndNewlines)
        return a.isEmpty ? configService.config.ownerNpub : a
    }
    private var isActive: Bool { npub == activeNpub }
    private var hasLocalKey: Bool {
        isOwner ? !configService.config.ownerNcryptsec.isEmpty : configService.hasCredential(forNpub: npub)
    }
    private var hasBunker: Bool { configService.hasBunkerConfig(forNpub: npub) }
    private var currentMode: String {
        configService.config.accountSigningModes[npub] ?? (hasBunker ? "nip46" : "local")
    }

    var body: some View {
        NavigationView {
            Form {
                // Header
                Section {
                    headerSection
                }

                // Switch to account
                if !isActive {
                    Section {
                        Button {
                            configService.switchActiveAccount(to: npub)
                            dismiss()
                        } label: {
                            Label("Switch to This Account", systemImage: "arrow.right.circle")
                        }
                    }
                }

                // Signing method picker
                if hasLocalKey && hasBunker {
                    Section {
                        Picker("Signing Method", selection: Binding(
                            get: { currentMode },
                            set: { newMode in
                                configService.setSigningMode(newMode, forNpub: npub)
                            }
                        )) {
                            Text("Local Key").tag("local")
                            Text("Remote Signer").tag("nip46")
                        }
                        .pickerStyle(.segmented)
                    } header: {
                        Text("Active Signing Method")
                    } footer: {
                        if currentMode == "nip46" {
                            Text("Events will be signed by the remote signer (NIP-46).")
                        } else {
                            Text("Events will be signed with the locally stored private key.")
                        }
                    }
                }

                // Local Key section
                Section {
                    if hasLocalKey {
                        HStack(spacing: 8) {
                            Image(systemName: "key.fill")
                                .foregroundColor(.orange)
                            Text("Private key stored")
                                .foregroundColor(.primary)
                            Spacer()
                            if !hasBunker {
                                // Only show active badge when there's no choice
                                Text("Active")
                                    .font(.appCaption)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.havenOnline.opacity(0.2))
                                    .foregroundColor(.havenOnline)
                                    .cornerRadius(4)
                            }
                        }

                        Button {
                            authenticateAndReveal()
                        } label: {
                            Label("Reveal Key", systemImage: "eye")
                        }

                        Button(role: .destructive) {
                            showingRemoveKeyConfirm = true
                        } label: {
                            Label("Remove Local Key", systemImage: "trash")
                        }
                    } else {
                        Button {
                            onImportKey()
                        } label: {
                            Label("Import Private Key", systemImage: "key")
                        }
                    }
                } header: {
                    Text("Local Key")
                }

                // Remote Signer section
                Section {
                    if hasBunker {
                        HStack(spacing: 8) {
                            Image(systemName: "link")
                                .foregroundColor(.blue)
                            Text("Remote signer configured")
                                .foregroundColor(.primary)
                            Spacer()
                            if isActive {
                                Circle()
                                    .fill(nip46Service.isConnected ? Color.havenOnline : Color.red)
                                    .frame(width: 8, height: 8)
                                Text(nip46Service.isConnected ? "Connected" : "Disconnected")
                                    .font(.appCaption)
                                    .foregroundColor(.secondary)
                            }
                        }

                        Button(role: .destructive) {
                            showingDisconnectSignerConfirm = true
                        } label: {
                            Label("Disconnect Remote Signer", systemImage: "link.badge.plus")
                        }
                    } else {
                        Button {
                            onConnectBunker()
                        } label: {
                            Label("Connect Remote Signer", systemImage: "link.badge.plus")
                        }
                    }
                } header: {
                    Text("Remote Signer (NIP-46)")
                }

                // NIP-65 Relay List Publishing
                if (hasLocalKey || hasBunker) && !configService.config.isLocal {
                    Section {
                        Toggle("Publish Inbox Relay", isOn: Binding(
                            get: { configService.config.publishRelayListPerAccount[npub] ?? false },
                            set: { enabled in
                                configService.config.publishRelayListPerAccount[npub] = enabled
                                configService.save()
                                if enabled {
                                    NostrService.shared.publishRelayList(forNpub: npub)
                                }
                            }
                        ))
                    } header: {
                        Text("Relay List (NIP-65)")
                    } footer: {
                        Text("Publishes this relay as the account's inbox so other clients know where to send events.")
                    }
                }

                // Remove account (non-owner only)
                if !isOwner {
                    Section {
                        Button(role: .destructive) {
                            showingRemoveAccountConfirm = true
                        } label: {
                            Label("Remove Account", systemImage: "person.badge.minus")
                        }
                    }
                }
            }
            .groupedFormStyleCompat()
            .confirmDestructive(
                "Remove Local Key",
                isPresented: $showingRemoveKeyConfirm,
                consequence: removeKeyConsequence,
                confirmTitle: "Remove Key",
                action: removeLocalKey
            )
            .confirmDestructive(
                "Disconnect Remote Signer",
                isPresented: $showingDisconnectSignerConfirm,
                consequence: disconnectSignerConsequence,
                confirmTitle: "Disconnect",
                action: disconnectRemoteSigner
            )
            .confirmDestructive(
                "Remove Account",
                isPresented: $showingRemoveAccountConfirm,
                consequence: "This removes \(npub.prefix(12))… from Nostr Vault, along with any key or signer stored for it. Nothing on the relays changes, but you will need the key again to sign back in.",
                confirmTitle: "Remove Account",
                action: {
                    onRemoveAccount()
                    dismiss()
                }
            )
            .navigationTitle("Account")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            #else
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            #endif
        }
    }

    /// What removing the local key costs, stated before it happens. Nostr Vault
    /// holds the only copy it knows about — if this was never written down,
    /// the account is unrecoverable.
    private var removeKeyConsequence: String {
        if hasBunker {
            return "This deletes the private key stored on this device. Signing falls back to the remote signer. If you have no backup of the key elsewhere, it cannot be recovered."
        }
        return "This deletes the private key stored on this device, and nothing else here can sign for this account afterwards. If you have no backup of the key elsewhere, it cannot be recovered."
    }

    private var disconnectSignerConsequence: String {
        if hasLocalKey {
            return "This drops the remote signer connection and its stored session. Signing falls back to the local key on this device; reconnecting needs a fresh bunker URI."
        }
        return "This drops the remote signer connection and its stored session, and nothing else here can sign for this account afterwards. Reconnecting needs a fresh bunker URI."
    }

    private func removeLocalKey() {
        if isOwner {
            configService.config.ownerNcryptsec = ""
            configService.config.ownerNsec = ""
        } else {
            configService.removeCredential(forNpub: npub)
        }
        // If was using local and now removed, switch to bunker if available
        if currentMode == "local" && hasBunker {
            configService.setSigningMode("nip46", forNpub: npub)
        }
        configService.save()
    }

    private func disconnectRemoteSigner() {
        if nip46Service.isConnected && isActive {
            nip46Service.disconnect()
        }
        configService.removeBunkerConfig(forNpub: npub)
        // If was using nip46 and now removed, switch to local
        if currentMode == "nip46" {
            configService.setSigningMode("local", forNpub: npub)
        }
    }

    private func authenticateAndReveal() {
        // Fail CLOSED: reveal the private key only after a successful device-owner
        // authentication (Face/Touch ID, or passcode fallback). The previous code
        // revealed the key with NO authentication when no biometry/passcode was
        // enrolled or LAContext errored — a fail-open leak of the signing key.
        // When auth is unavailable, evaluatePolicy calls back success=false, so we
        // simply don't reveal.
        let context = LAContext()
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Authenticate to reveal your private key") { success, _ in
            DispatchQueue.main.async {
                if success {
                    onRevealKey()
                }
            }
        }
    }

    @ViewBuilder
    private var headerSection: some View {
        let hex = Bech32.decode(npub)?.hexString ?? ""
        let profile = nostrService.profiles[hex]
        let displayName = profile?.bestName ?? String(npub.prefix(12)) + "..."

        HStack(spacing: 12) {
            AvatarView(url: profile?.pictureURL, pubkey: hex)
                .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(displayName).fontWeight(.semibold)
                    if isOwner {
                        Text("Owner")
                            .font(.appSystem(size: 10, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.havenPurple.opacity(0.2))
                            .foregroundColor(.havenPurple)
                            .cornerRadius(4)
                    }
                    if isActive {
                        Text("Active")
                            .font(.appSystem(size: 10, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.havenOnline.opacity(0.2))
                            .foregroundColor(.havenOnline)
                            .cornerRadius(4)
                    }
                }
                Text(npub)
                    .font(.appSystem(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}

// MARK: - Connect Signer Sheet

struct ConnectSignerSheetView: View {
    @Environment(\.dismiss) private var dismiss
    var onDismiss: (() -> Void)? = nil
    @ObservedObject var configService: ConfigService
    let npub: String

    @State private var bunkerURI: String = ""
    @State private var isConnecting = false
    @State private var errorMessage: String? = nil
    #if os(iOS)
    @State private var showQRScanner = false
    #endif

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") { performDismiss() }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                Spacer()
                Text("Connect Remote Signer")
                    .font(.appHeadline)
                Spacer()
                Button("Connect") { connectBunker() }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.havenPurple)
                    .disabled(bunkerURI.isEmpty || isConnecting)
            }
            .padding()

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Text("Paste the bunker:// URI from your remote signer app to connect it to this account.")
                    .font(.appCaption)
                    .foregroundColor(.secondary)

                TextField("bunker://...", text: $bunkerURI)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.URL)

                if let error = errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.appCaption)
                        .foregroundColor(.red)
                }

                if isConnecting {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Connecting...").font(.appCaption).foregroundColor(.secondary)
                    }
                }
            }
            .padding()
        }
        .frame(width: 420)
        #else
        NavigationView {
            Form {
                Section {
                    HStack(spacing: 8) {
                        TextField("bunker://...", text: $bunkerURI)
                            .textContentType(.URL)
                            .autocapitalization(.none)

                        Button(action: { showQRScanner = true }) {
                            Image(systemName: "qrcode.viewfinder")
                                .font(.appSystem(size: 20))
                                .foregroundColor(Color.havenPurple)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Scan QR code")
                    }
                } header: {
                    Text("Bunker URI")
                } footer: {
                    Text("Paste or scan the bunker:// connection string from your remote signer app.")
                }

                if let error = errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.appCaption)
                            .foregroundColor(.red)
                    }
                }

                Section {
                    Button(action: connectBunker) {
                        HStack {
                            Text("Connect")
                            if isConnecting {
                                Spacer()
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                    .disabled(bunkerURI.isEmpty || isConnecting)
                }
            }
            .navigationTitle("Connect Signer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { performDismiss() }
                }
            }
            .sheet(isPresented: $showQRScanner) {
                QRScannerView(
                    title: "Scan your signer’s bunker code",
                    validate: { code in
                        BunkerURI.normalized(code) == nil
                            ? "That QR code is not a bunker:// connection string"
                            : nil
                    }
                ) { scannedCode in
                    showQRScanner = false
                    guard let uri = BunkerURI.normalized(scannedCode) else { return }
                    bunkerURI = uri
                    errorMessage = nil
                }
            }
        }
        #endif
    }

    private func connectBunker() {
        isConnecting = true
        errorMessage = nil

        Task {
            do {
                let info = try NIP46Service.parseBunkerURI(bunkerURI)

                var bunkerConfig = AccountBunkerConfig(
                    bunkerURI: bunkerURI,
                    signerPubkey: info.signerPubkey,
                    relayURL: info.relayURL,
                    secret: info.secret
                )

                // Generate a client keypair for this account's connection
                if let keyPairCStr = GenerateKeyPairC() {
                    let keyPairStr = String(cString: keyPairCStr)
                    free(keyPairCStr)
                    let parts = keyPairStr.split(separator: ":")
                    if parts.count == 2 {
                        bunkerConfig.clientSecretKey = String(parts[0])
                        bunkerConfig.clientPubkey = String(parts[1])
                    }
                }

                configService.setBunkerConfig(bunkerConfig, forNpub: npub)
                // Set signing mode to nip46 for this account
                configService.setSigningMode("nip46", forNpub: npub)

                // If this is the active account, connect now
                let activeNpub = configService.config.activeAccountNpub.isEmpty ? configService.config.ownerNpub : configService.config.activeAccountNpub
                if npub == activeNpub && !NIP46Service.shared.isConnected {
                    try await NIP46Service.shared.connect()
                }

                isConnecting = false
                performDismiss()
            } catch {
                errorMessage = error.localizedDescription
                isConnecting = false
                configService.removeBunkerConfig(forNpub: npub)
            }
        }
    }

    private func performDismiss() {
        onDismiss?()
        dismiss()
    }
}

struct AddAccountSheetView: View {
    @Environment(\.dismiss) private var dismiss
    var onDismiss: (() -> Void)? = nil
    @ObservedObject var configService: ConfigService
    @State private var addInput = ""
    @State private var addError: String? = nil

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") {
                    performDismiss()
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                
                Spacer()
                
                Text("Add Account")
                    .font(.appHeadline)
                
                Spacer()
                
                Button("Add") {
                    processAddAccount()
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.havenPurple)
                .disabled(addInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
            .background(Color.platformControlBackground.opacity(0.5))
            
            VStack(alignment: .leading, spacing: 12) {
                Text("Npub")
                    .font(.appSystem(size: 13, weight: .semibold))
                    .foregroundColor(.secondary)
                
                TextEditor(text: $addInput)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 80)
                    .padding(6)
                    .background(Color.platformControlBackground)
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                    )
                
                if let error = addError {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.appCaption)
                }
            }
            .padding(20)
            
            Spacer()
        }
        .background(Color.platformSecondaryGroupedBackground)
        .frame(width: 460, height: 210)
        #else
        NavigationView {
            Form {
                Section("Npub") {
                    TextEditor(text: $addInput)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 80)
                }
                if let error = addError { Text(error).foregroundColor(.red) }
            }
            .navigationTitle("Add Account")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { performDismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Add") { processAddAccount() } }
            }
        }
        #endif
    }

    private func processAddAccount() {
        let input = addInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard input.starts(with: "npub") else {
            addError = "Must be an npub"; return
        }
        if !configService.config.whitelistedNpubs.contains(input) {
            configService.config.whitelistedNpubs.append(input)
        }
        configService.save()
        performDismiss()
    }

    private func performDismiss() {
        if let onDismiss = onDismiss {
            onDismiss()
        } else {
            dismiss()
        }
    }
}

struct ImportKeySheetView: View {
    @Environment(\.dismiss) private var dismiss
    var onDismiss: (() -> Void)? = nil
    @ObservedObject var configService: ConfigService
    let npub: String

    @State private var importNsec = ""
    @State private var importPassword = ""
    @State private var importConfirm = ""
    @State private var importError: String? = nil

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") {
                    performDismiss()
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                
                Spacer()
                
                Text("Import Key")
                    .font(.appHeadline)
                
                Spacer()
                
                Button("Import") {
                    processImport()
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.havenPurple)
                .disabled(importNsec.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || importPassword.isEmpty || importConfirm.isEmpty)
            }
            .padding()
            .background(Color.platformControlBackground.opacity(0.5))
            
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Private Key (nsec)")
                            .font(.appSystem(size: 13, weight: .semibold))
                            .foregroundColor(.secondary)
                        
                        TextEditor(text: $importNsec)
                            .font(.system(.body, design: .monospaced))
                            .frame(height: 80)
                            .padding(6)
                            .background(Color.platformControlBackground)
                            .cornerRadius(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                            )
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Encrypt with Password")
                            .font(.appSystem(size: 13, weight: .semibold))
                            .foregroundColor(.secondary)

                        // Hidden username field anchors AutoFill to the npub
                        // so the nsec is not captured as the username.
                        TextField("", text: .constant(npub))
                            .textContentType(.username)
                            .frame(width: 0, height: 0)
                            .opacity(0)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)

                        SecureField("Password", text: $importPassword)
                            .textFieldStyle(.roundedBorder)
                            .textContentType(.newPassword)
                            .font(.appBody)

                        SecureField("Confirm Password", text: $importConfirm)
                            .textFieldStyle(.roundedBorder)
                            .textContentType(.newPassword)
                            .font(.appBody)
                    }
                    
                    if let error = importError {
                        Text(error)
                            .foregroundColor(.red)
                            .font(.appCaption)
                    }
                }
                .padding(20)
            }
        }
        .background(Color.platformSecondaryGroupedBackground)
        .frame(width: 480, height: 350)
        #else
        NavigationView {
            Form {
                Section("Private Key") {
                    TextEditor(text: $importNsec).font(.system(.body, design: .monospaced)).frame(minHeight: 80)
                }
                Section("Encrypt with Password") {
                    // Hidden username field anchors AutoFill to the npub
                    // so the nsec is not captured as the username.
                    TextField("", text: .constant(npub))
                        .textContentType(.username)
                        .frame(width: 0, height: 0)
                        .opacity(0)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    SecureField("Password", text: $importPassword)
                        .textContentType(.newPassword)
                    SecureField("Confirm", text: $importConfirm)
                        .textContentType(.newPassword)
                }
                if let error = importError { Text(error).foregroundColor(.red) }
            }
            .navigationTitle("Import Key")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { performDismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Import") {
                    processImport()
                }}
            }
        }
        #endif
    }

    private func processImport() {
        guard importPassword == importConfirm, importPassword.count >= 8 else {
            importError = "Password must be at least 8 characters and match confirm password"
            return
        }
        do {
            if npub == configService.config.ownerNpub {
                try configService.config.setEncryptedNsec(nsec: importNsec, password: importPassword)
                _ = NIP49Service.storePasswordInKeychain(importPassword)
                configService.save()
            } else {
                try configService.setCredential(nsec: importNsec, password: importPassword, forNpub: npub)
            }
            performDismiss()
        } catch {
            importError = "Failed to import and encrypt key"
        }
    }

    private func performDismiss() {
        if let onDismiss = onDismiss {
            onDismiss()
        } else {
            dismiss()
        }
    }
}

struct RevealKeySheetView: View {
    @Environment(\.dismiss) private var dismiss
    var onDismiss: (() -> Void)? = nil
    @ObservedObject var configService: ConfigService
    let npub: String

    @State private var password = ""
    @State private var revealedNsec: String? = nil
    @State private var errorMessage: String? = nil
    @State private var copied = false

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") {
                    performDismiss()
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)

                Spacer()

                Text("Reveal Private Key")
                    .font(.appHeadline)

                Spacer()

                if revealedNsec == nil {
                    Button("Unlock") {
                        decryptKey()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.havenPurple)
                    .disabled(password.isEmpty)
                } else {
                    Button("Done") {
                        performDismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.havenPurple)
                }
            }
            .padding()
            .background(Color.platformControlBackground.opacity(0.5))

            VStack(alignment: .leading, spacing: 16) {
                if let nsec = revealedNsec {
                    revealedKeyContent(nsec: nsec)
                } else {
                    passwordEntryContent()
                }
            }
            .padding(20)

            Spacer()
        }
        .background(Color.platformSecondaryGroupedBackground)
        .frame(width: 480, height: revealedNsec != nil ? 280 : 220)
        #else
        NavigationView {
            Form {
                if let nsec = revealedNsec {
                    Section("Private Key") {
                        revealedKeyContent(nsec: nsec)
                    }
                } else {
                    Section("Enter Password") {
                        SecureField("NIP-49 Password", text: $password)
                            .textContentType(.password)
                            .onSubmit { decryptKey() }
                    }
                    if let error = errorMessage {
                        Text(error).foregroundColor(.red).font(.appCaption)
                    }
                }
            }
            .navigationTitle("Reveal Private Key")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { performDismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if revealedNsec == nil {
                        Button("Unlock") { decryptKey() }
                            .disabled(password.isEmpty)
                    } else {
                        Button("Done") { performDismiss() }
                    }
                }
            }
        }
        #endif
    }

    @ViewBuilder
    private func passwordEntryContent() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Enter Password")
                .font(.appSystem(size: 13, weight: .semibold))
                .foregroundColor(.secondary)

            SecureField("NIP-49 Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .textContentType(.password)
                .font(.appBody)
                .onSubmit { decryptKey() }
        }

        if let error = errorMessage {
            Text(error)
                .foregroundColor(.red)
                .font(.appCaption)
        }
    }

    @ViewBuilder
    private func revealedKeyContent(nsec: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your Private Key (nsec)")
                .font(.appSystem(size: 13, weight: .semibold))
                .foregroundColor(.secondary)

            Text(nsec)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .textSelection(.enabled)
                .lineLimit(3)
                .minimumScaleFactor(0.7)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.platformControlBackground)
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                )

            Button {
                copyNsec(nsec)
            } label: {
                Label(
                    copied ? "Copied!" : "Copy to Clipboard",
                    systemImage: copied ? "checkmark" : "doc.on.doc"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Text("Keep this key safe. Anyone with your nsec has full control of your Nostr identity.")
                .font(.appCaption2)
                .foregroundColor(.orange)
        }
    }

    private func decryptKey() {
        guard !password.isEmpty else { return }
        errorMessage = nil

        let isOwner = (npub == configService.config.ownerNpub)

        do {
            let nsec: String
            if isOwner {
                nsec = try configService.config.getDecryptedNsec(password: password)
            } else {
                guard let ncryptsec = configService.config.accountCredentials[npub],
                      !ncryptsec.isEmpty else {
                    errorMessage = "No encrypted key found for this account"
                    return
                }
                nsec = try NIP49Service.decrypt(ncryptsec: ncryptsec, password: password)
            }
            revealedNsec = nsec
        } catch {
            errorMessage = "Incorrect password or decryption failed"
        }
    }

    private func copyNsec(_ nsec: String) {
        PlatformClipboard.copy(nsec)
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run { copied = false }
        }
    }

    private func performDismiss() {
        revealedNsec = nil
        password = ""
        errorMessage = nil

        if let onDismiss = onDismiss {
            onDismiss()
        } else {
            dismiss()
        }
    }
}

struct BlockedSettingsView: View {
    @EnvironmentObject var configService: ConfigService
    @ObservedObject private var nostrService = NostrService.shared
    
    @State private var searchInput = ""
    @State private var isSearching = false
    
    var blockedNpubs: [String] {
        let active = configService.config.activeAccountNpub.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetNpub = active.isEmpty ? configService.config.ownerNpub : active
        return configService.config.blockedNpubsPerAccount[targetNpub] ?? []
    }

    var throttledAccounts: [(npub: String, maxPosts: Int)] {
        let active = configService.config.activeAccountNpub.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetNpub = active.isEmpty ? configService.config.ownerNpub : active
        let dict = configService.config.throttledAccountsPerAccount[targetNpub] ?? [:]
        return dict.map { (npub: $0.key, maxPosts: $0.value) }
            .sorted { $0.npub < $1.npub }
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("npub1...", text: $searchInput)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                    Button("Block") {
                        if searchInput.starts(with: "npub1") {
                            configService.blockProfile(searchInput.trimmingCharacters(in: .whitespacesAndNewlines))
                            searchInput = ""
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!searchInput.starts(with: "npub1"))
                }
            } header: {
                Text("Block Profile")
            } footer: {
                Text("Enter an npub to block it. Blocked profiles cannot interact with you.")
            }

            Section("Blocked Accounts") {
                if blockedNpubs.isEmpty {
                    Text("No blocked accounts.").foregroundColor(.secondary)
                } else {
                    ForEach(blockedNpubs, id: \.self) { npub in
                        let hex = Bech32.decode(npub)?.hexString ?? ""
                        let profile = nostrService.profiles[hex]
                        let displayName = profile?.bestName ?? String(npub.prefix(12)) + "..."

                        HStack {
                            AvatarView(url: profile?.pictureURL, pubkey: hex)
                                .frame(width: 32, height: 32)
                            VStack(alignment: .leading) {
                                Text(displayName).fontWeight(.semibold)
                                Text(npub).font(.appSystem(size: 10, design: .monospaced)).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Button("Unblock") {
                                configService.unblockProfile(npub)
                            }.foregroundColor(.red)
                        }
                    }
                }
            }

            Section {
                if throttledAccounts.isEmpty {
                    Text("No slowed-down accounts.").foregroundColor(.secondary)
                } else {
                    ForEach(throttledAccounts, id: \.npub) { entry in
                        let hex = Bech32.decode(entry.npub)?.hexString ?? ""
                        let profile = nostrService.profiles[hex]
                        let displayName = profile?.bestName ?? String(entry.npub.prefix(12)) + "..."

                        HStack {
                            AvatarView(url: profile?.pictureURL, pubkey: hex)
                                .frame(width: 32, height: 32)
                            VStack(alignment: .leading) {
                                Text(displayName).fontWeight(.semibold)
                                Text("Max \(entry.maxPosts) post\(entry.maxPosts == 1 ? "" : "s") visible")
                                    .font(.appCaption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Stepper("", value: Binding(
                                get: { entry.maxPosts },
                                set: { configService.throttleProfile(entry.npub, maxPosts: $0) }
                            ), in: 1...20)
                            .labelsHidden()
                            .frame(width: 100)
                            Button {
                                configService.unthrottleProfile(entry.npub)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } header: {
                Text("Slowed Down")
            } footer: {
                Text("Slowed-down accounts have a limit on how many of their posts appear in your feed at once. Tap a username in the feed to slow someone down.")
            }
        }
        .groupedFormStyleCompat()
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

struct AdvancedSettingsView: View {
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var relayManager: RelayProcessManager
    @State private var showResetConfirmation = false

    var body: some View {
        Form {
            Section {
                Stepper("Max Events: \(configService.config.outboxMaxEventsPerMinute) / min", 
                       value: $configService.config.outboxMaxEventsPerMinute, in: 10...1000, step: 10)
                
                Stepper("Max Connections: \(configService.config.outboxMaxConnectionsPerMinute) / min",
                       value: $configService.config.outboxMaxConnectionsPerMinute, in: 1...100)
            } header: {
                Text("Performance & Limits")
            } footer: {
               Text("These limits help protect your relay from spam and abuse.")
            }
            
            Section {
                HStack {
                    Text("Engine")
                    Spacer()
                    Text(configService.config.dbEngine == "badger" ? "BadgerDB" : "LMDB")
                        .foregroundColor(.secondary)
                }
                
                #if os(macOS)
                HStack {
                    Text("Blossom Path")
                    Spacer()
                    Text(configService.config.blossomPath)
                        .foregroundColor(.secondary)
                    
                    Button {
                        let fullPath = configService.relayDataDir.appendingPathComponent(configService.config.blossomPath).path
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: fullPath)
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.plain)
                }
                #endif
            } header: {
                Text("Database")
            } footer: {
                Text(configService.config.dbEngine == "badger" ? 
                     "BadgerDB pre-allocates ~11GB of space. This is normal." :
                     "LMDB uses sparse files.")
            }
            
            Section {
                Toggle("Autoplay Videos", isOn: $configService.config.autoplayVideos)
                Toggle("Disable Media Cache", isOn: $configService.config.disableMediaCache)
                Toggle("Prefetch Profile Pictures", isOn: $configService.config.prefetchProfilePictures)

                Picker("Cache TTL", selection: $configService.config.cacheTTLDays) {
                    Text("1 day").tag(1)
                    Text("3 days").tag(3)
                    Text("7 days").tag(7)
                    Text("14 days").tag(14)
                    Text("30 days").tag(30)
                    Text("Never").tag(0)
                }

                Button(role: .destructive) {
                    MediaCacheService.shared.clearCache()
                } label: {
                    Label("Clear Media Cache", systemImage: "trash")
                }
            } header: {
                Text("Media")
            } footer: {
                Text("When autoplay is off, videos show a thumbnail until tapped. Cache TTL controls how long downloaded media is kept before automatic cleanup. Clearing the cache will remove downloaded remote images but won't touch your local Blossom data. Profile picture prefetching downloads avatars for all followed accounts once per day over Wi-Fi only.")
            }

            Section {
                Stepper("Depth: \(configService.config.chatRelayWotDepth)", 
                       value: $configService.config.chatRelayWotDepth, in: 1...5)
                Stepper("Minimum Followers: \(configService.config.chatRelayMinFollowers)",
                       value: $configService.config.chatRelayMinFollowers, in: 0...100)
                
                Picker("Refresh Interval", selection: $configService.config.wotRefreshInterval) {
                    Text("1 Hour").tag("1h")
                    Text("12 Hours").tag("12h")
                    Text("24 Hours").tag("24h")
                    Text("7 Days").tag("168h")
                }
            } header: {
                Text("Global Web of Trust")
            } footer: {
                Text("WoT determines who can post to your inbox and chat relays. Lower depth is more private.")
            }
            
            Section("Diagnostics & Startup") {
                #if os(macOS)
                Toggle("Launch at Login", isOn: $configService.config.launchAtLogin)
                #endif
                Toggle("Auto-start Relay", isOn: $configService.config.autoStartRelay)
            }
            
            Section {
                Button(role: .destructive) {
                    showResetConfirmation = true
                } label: {
                    Label("Factory Reset", systemImage: "trash")
                        .foregroundColor(.red)
                }
            } header: {
                Text("Danger Zone")
            } footer: {
                Text("This will stop the relay, delete all data (database, logs), and reset settings to default.")
            }
        }
        .groupedFormStyleCompat()
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .alert("Are you sure?", isPresented: $showResetConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Reset Everything", role: .destructive) {
                relayManager.stopRelay {
                    Task { @MainActor in
                        configService.resetApp()
                        ConfigService.quitApp()
                    }
                }
            }
        } message: {
            Text("This action cannot be undone. All your relay data will be lost and the app will quit.")
        }
    }

}


struct ImportSettingsView: View {
    @EnvironmentObject var configService: ConfigService

    private var importDateBinding: Binding<Date> {
        Binding<Date>(
            get: {
                let fmt = DateFormatter()
                fmt.dateFormat = "yyyy-MM-dd"
                fmt.timeZone = TimeZone(identifier: "UTC")
                return fmt.date(from: configService.config.importStartDate) ?? Date()
            },
            set: { newDate in
                let fmt = DateFormatter()
                fmt.dateFormat = "yyyy-MM-dd"
                fmt.timeZone = TimeZone(identifier: "UTC")
                configService.config.importStartDate = fmt.string(from: newDate)
            }
        )
    }

    var body: some View {
        Form {
            Section {
                DatePicker("Start Date", selection: importDateBinding, displayedComponents: .date)
                TextField("Seed Relays File", text: $configService.config.importSeedRelaysFile)
            } header: {
                Text("Import Configuration")
            } footer: {
                Text("Notes will be fetched starting from this date.")
            }
            
            Section {
                RelayListEditor(relays: $configService.config.importSeedRelays)
            } header: {
                Text("Seed Relays")
            } footer: {
                Text("The import process will fetch your own notes and notes where you are tagged. Make sure you have your npub set correctly in the Identity tab.")
            }
        }
        .groupedFormStyleCompat()
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

struct BackupSettingsView: View {
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var relayManager: RelayProcessManager

    enum ImportType {
        case jsonl
        case blossom
    }

    @State private var isExportingJSONL = false
    @State private var isImportingJSONL = false
    @State private var isExportingBlossom = false
    @State private var isImportingBlossom = false
    @State private var statusMessage = ""
    @State private var activeImportType: ImportType?
    @State private var showFileImporter = false
    
    var body: some View {
        Form {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Export Notes")
                            .font(.appBody)
                        Text("Save all notes and metadata as a JSONL backup")
                            .font(.appCaption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(action: exportJSONL) {
                        HStack(spacing: 6) {
                            if isExportingJSONL {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "arrow.up.doc.fill")
                            }
                            Text("Export")
                        }
                    }
                    .disabled(isExportingJSONL || isImportingJSONL || isExportingBlossom || isImportingBlossom)
                }
                
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Import Notes")
                            .font(.appBody)
                        Text("Restore notes from a Nostr Vault JSONL backup (.zip)")
                            .font(.appCaption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(action: importJSONL) {
                        HStack(spacing: 6) {
                            if isImportingJSONL {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "arrow.down.doc.fill")
                            }
                            Text("Import")
                        }
                    }
                    .disabled(isExportingJSONL || isImportingJSONL || isExportingBlossom || isImportingBlossom)
                }
            } header: {
                Text("Notes (JSONL)")
            } footer: {
                Text("Export creates a compressed backup of all your notes. Import restores from a previously exported backup.")
            }
            
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Export Media")
                            .font(.appBody)
                        Text("Save all Blossom media files as a backup")
                            .font(.appCaption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(action: exportBlossom) {
                        HStack(spacing: 6) {
                            if isExportingBlossom {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "photo.stack")
                            }
                            Text("Export")
                        }
                    }
                    .disabled(isExportingJSONL || isImportingJSONL || isExportingBlossom || isImportingBlossom)
                }
                
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Import Media")
                            .font(.appBody)
                        Text("Restore media from a Blossom backup (.zip)")
                            .font(.appCaption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(action: importBlossom) {
                        HStack(spacing: 6) {
                            if isImportingBlossom {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "photo.badge.arrow.down")
                            }
                            Text("Import")
                        }
                    }
                    .disabled(isExportingJSONL || isImportingJSONL || isExportingBlossom || isImportingBlossom)
                }
            } header: {
                Text("Media (Blossom)")
            } footer: {
                Text("Export creates a compressed backup of your images and videos. Import restores media from a previously exported backup.")
            }

            if !statusMessage.isEmpty {
                Section {
                    HStack {
                        Image(systemName: statusMessage.contains("failed") || statusMessage.contains("Error") ? "xmark.circle.fill" : "checkmark.circle.fill")
                            .foregroundColor(statusMessage.contains("failed") || statusMessage.contains("Error") ? .red : .havenOnline)
                        Text(statusMessage)
                            .font(.appCallout)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .groupedFormStyleCompat()
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.zip], allowsMultipleSelection: false) { result in
            switch activeImportType {
            case .jsonl:
                handleJSONLImport(result)
            case .blossom:
                handleBlossomImport(result)
            case .none:
                break
            }
        }
        #endif
    }
    
    // MARK: - JSONL Export
    
    private func exportJSONL() {
        isExportingJSONL = true
        statusMessage = "Preparing JSONL export..."
        
        let tempDir = NSTemporaryDirectory()
        let tempPath = (tempDir as NSString).appendingPathComponent("nostrvault-backup-\(Date().timeIntervalSince1970).zip")
        
        relayManager.runBackupExport(config: configService.config, outputPath: tempPath) { success in
            Task { @MainActor in
                isExportingJSONL = false
                guard success else {
                    statusMessage = "JSONL export failed"
                    clearStatus()
                    return
                }
                #if os(macOS)
                presentSavePanel(title: "Save JSONL Backup", defaultName: "nostrvault-backup.zip", tempPath: tempPath)
                #else
                shareFile(at: tempPath)
                #endif
            }
        }
    }
    
    // MARK: - JSONL Import
    
    private func importJSONL() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.title = "Choose JSONL Backup"
        panel.allowedContentTypes = [.zip]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        performJSONLRestore(from: url)
        #else
        activeImportType = .jsonl
        showFileImporter = true
        #endif
    }
    
    #if os(iOS)
    private func handleJSONLImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            performJSONLRestore(from: url)
        case .failure(let error):
            statusMessage = "Import error: \(error.localizedDescription)"
            clearStatus()
        }
    }
    #endif
    
    private func performJSONLRestore(from url: URL) {
        isImportingJSONL = true
        statusMessage = "Restoring notes..."
        
        // Copy to temp to avoid sandbox issues
        let tempFile = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("restore-\(UUID().uuidString).zip")
        
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        
        do {
            try FileManager.default.copyItem(at: url, to: tempFile)
        } catch {
            isImportingJSONL = false
            statusMessage = "Error copying file: \(error.localizedDescription)"
            clearStatus()
            return
        }
        
        relayManager.runBackupRestore(config: configService.config, inputPath: tempFile.path) { success in
            Task { @MainActor in
                isImportingJSONL = false
                try? FileManager.default.removeItem(at: tempFile)
                statusMessage = success ? "Notes restored successfully!" : "Note restore failed"
                clearStatus()
            }
        }
    }
    
    // MARK: - Blossom Export
    
    private func exportBlossom() {
        isExportingBlossom = true
        statusMessage = "Preparing Blossom export..."
        
        let tempDir = NSTemporaryDirectory()
        let tempPath = (tempDir as NSString).appendingPathComponent("blossom-backup-\(Date().timeIntervalSince1970).zip")
        
        relayManager.runBlossomExportWithExtensions(config: configService.config, outputPath: tempPath) { success in
            Task { @MainActor in
                isExportingBlossom = false
                guard success else {
                    statusMessage = "Blossom export failed"
                    clearStatus()
                    return
                }
                #if os(macOS)
                presentSavePanel(title: "Save Blossom Backup", defaultName: "blossom-backup.zip", tempPath: tempPath)
                #else
                shareFile(at: tempPath)
                #endif
            }
        }
    }
    
    // MARK: - Blossom Import
    
    private func importBlossom() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.title = "Choose Blossom Backup"
        panel.allowedContentTypes = [.zip]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        performBlossomRestore(from: url)
        #else
        activeImportType = .blossom
        showFileImporter = true
        #endif
    }
    
    #if os(iOS)
    private func handleBlossomImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            performBlossomRestore(from: url)
        case .failure(let error):
            statusMessage = "Import error: \(error.localizedDescription)"
            clearStatus()
        }
    }
    #endif
    
    private func performBlossomRestore(from url: URL) {
        isImportingBlossom = true
        statusMessage = "Restoring media..."
        
        let tempFile = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("blossom-restore-\(UUID().uuidString).zip")
        
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        
        do {
            try FileManager.default.copyItem(at: url, to: tempFile)
        } catch {
            isImportingBlossom = false
            statusMessage = "Error copying file: \(error.localizedDescription)"
            clearStatus()
            return
        }
        
        relayManager.runBlossomImportStrippingExtensions(config: configService.config, inputPath: tempFile.path) { success in
            Task { @MainActor in
                isImportingBlossom = false
                try? FileManager.default.removeItem(at: tempFile)
                statusMessage = success ? "Media restored successfully!" : "Media restore failed"
                clearStatus()
            }
        }
    }
    
    // MARK: - Helpers
    
    #if os(macOS)
    private func presentSavePanel(title: String, defaultName: String, tempPath: String) {
        let panel = NSSavePanel()
        panel.title = title
        panel.nameFieldStringValue = defaultName
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        
        if panel.runModal() == .OK, let destURL = panel.url {
            let srcURL = URL(fileURLWithPath: tempPath)
            do {
                if FileManager.default.fileExists(atPath: destURL.path) {
                    try FileManager.default.removeItem(at: destURL)
                }
                try FileManager.default.moveItem(at: srcURL, to: destURL)
                statusMessage = "Saved to \(destURL.lastPathComponent)"
            } catch {
                statusMessage = "Failed to save: \(error.localizedDescription)"
            }
        } else {
            statusMessage = "Export cancelled"
            try? FileManager.default.removeItem(atPath: tempPath)
        }
        clearStatus()
    }
    #endif
    
    #if os(iOS)
    private func shareFile(at path: String) {
        let fileURL = URL(fileURLWithPath: path)
        let activityVC = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
        
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = scene.windows.first,
           let rootVC = window.rootViewController {
            rootVC.present(activityVC, animated: true)
        }
    }
    #endif
    
    private func clearStatus() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            statusMessage = ""
        }
    }

}

struct FeedSettingsView: View {
    @EnvironmentObject var configService: ConfigService

    var body: some View {
        Form {
            Section {
                RelayListEditor(relays: $configService.config.feedRelays)
            } header: {
                Text("Feed Relays")
            } footer: {
                Text("The feed reads from multiple relays to build your timeline. Connect to relays your followers are actively using.")
            }
        }
        .groupedFormStyleCompat()
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

struct DMSettingsView: View {
    @EnvironmentObject var configService: ConfigService
    @State private var showPublishSuccess = false
    @State private var publishTask: Task<Void, Never>?

    var body: some View {
        Form {
            Section {
                RelayListEditor(relays: $configService.config.dmRelays)
                    .onChange(of: configService.config.dmRelays) { _, _ in
                        // Auto-publish when relays change (debounced)
                        publishTask?.cancel()
                        publishTask = Task {
                            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 second debounce
                            if !Task.isCancelled {
                                publishDMRelayList()
                            }
                        }
                    }
            } header: {
                Text("DM Relays")
            } footer: {
                Text("NIP-17 encrypted DMs are sent to these relays. Your local Haven relay and Mac relay (if configured) are automatically added when publishing.")
            }

            if showPublishSuccess {
                Section {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.havenOnline)
                        Text("DM relay preferences published to network")
                            .font(.appCaption)
                    }
                }
                .transition(.opacity)
            }
        }
        .groupedFormStyleCompat()
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onDisappear {
            publishTask?.cancel()
        }
    }

    private func publishDMRelayList() {
        var relays = configService.config.dmRelays

        // Deliberately NOT including the local relay. This list tells other
        // people where to deliver our DMs, and our 127.0.0.1 is their own
        // machine — senders wrote the gift wrap into their own relay and we
        // received nothing. Our client subscribes to the local relay directly;
        // it never needed advertising. publishDMRelayList filters loopback too,
        // so a stale saved list can't reintroduce it.

        // Include Mac relay if configured
        if !configService.config.macRelayURL.isEmpty && !relays.contains(configService.config.macRelayURL) {
            relays.append(configService.config.macRelayURL)
        }

        NostrService.shared.publishDMRelayList(dmRelays: relays)

        // Show success feedback
        showPublishSuccess = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            showPublishSuccess = false
        }
    }
}

struct BlastrSettingsView: View {
    @EnvironmentObject var configService: ConfigService
    
    var body: some View {
        Form {
            Section {
                TextField("Blastr Relays File", text: $configService.config.blastrRelaysFile)
            } header: {
                Text("Blastr Configuration")
            } footer: {
               Text("The JSON file containing relays to broadcast notes to.")
            }
            
            Section {
                RelayListEditor(relays: $configService.config.blastrRelays)
            } header: {
                Text("Broadcast Relays")
            } footer: {
                Text("Blastr automatically broadcasts your local notes to these external relays.")
            }
        }
        .groupedFormStyleCompat()
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

private struct NewMirrorInputView: View {
    @Binding var url: String
    var onAdd: () -> Void
    
    var body: some View {
        HStack {
            TextField("https://example.com", text: $url)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                #endif

            Button(action: onAdd) {
                Image(systemName: "plus.circle.fill")
                    .foregroundColor(.havenOnline)
            }
            .disabled(url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}



struct WalletSettingsView: View {
    @EnvironmentObject var configService: ConfigService
    @State private var balance: Int? = nil
    @State private var isFetchingBalance = false
    @State private var balanceError: String? = nil
    @State private var taprootAddress: String = ""
    @State private var addressCopied = false
    @State private var showSweepDisclaimer = false

    var body: some View {
        Form {
            Section {
                TextEditor(text: $configService.config.nwcURI)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 80)
                    .padding(4)
                    .background(Color.platformControlBackground)
                    .cornerRadius(6)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
            } header: {
                Text("Nostr Wallet Connect (NWC) URI")
            } footer: {
                Text("Paste your nostr+walletconnect:// URI here to enable sending Zaps directly from Nostr Vault.")
            }

            if !configService.config.nwcURI.isEmpty {
                Section("Wallet Output") {
                    HStack {
                        Text("Default Zap Amount")
                        Spacer()
                        let amountSats = configService.config.defaultZapAmount / 1000
                        TextField("Sats", value: Binding(
                            get: { amountSats },
                            set: { configService.config.defaultZapAmount = $0 * 1000 }
                        ), formatter: NumberFormatter())
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                        Text("sats")
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("Balance")
                        Spacer()
                        if isFetchingBalance {
                            ProgressView().controlSize(.small)
                        } else if let bal = balance {
                            Text("\(bal / 1000) sats")
                                .foregroundColor(.secondary)
                        } else if let error = balanceError {
                            Text(error)
                                .foregroundColor(.red)
                                .font(.appCaption)
                        } else {
                            Text("Unknown")
                                .foregroundColor(.secondary)
                        }

                        Button {
                            fetchBalance()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.plain)
                        .disabled(isFetchingBalance)
                    }
                }
            }

            // Cashu Ecash Mint
            Section {
                TextEditor(text: $configService.config.cashuMintURL)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 60)
                    .padding(4)
                    .background(Color.platformControlBackground)
                    .cornerRadius(6)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                    .onChange(of: configService.config.cashuMintURL) { _, _ in
                        configService.save()
                    }
            } header: {
                Text("Cashu Mint URL")
            } footer: {
                Text("Enter a Cashu mint URL to enable the ecash wallet. Example: https://mint.minibits.cash/Bitcoin")
            }

            if !configService.config.cashuMintURL.isEmpty {
                Section("Ecash Wallet") {
                    HStack {
                        Text("Balance")
                        Spacer()
                        Text("\(CashuService.shared.balanceSats) sats")
                            .foregroundColor(.secondary)
                    }
                }
            }

            // Bitcoin Taproot wallet derived from Nostr keypair (BIP-341)
            Section {
                Toggle(isOn: $configService.config.showBitcoinWallet) {
                    Label("Bitcoin Address", systemImage: "bitcoinsign.circle")
                }
                .onChange(of: configService.config.showBitcoinWallet) { _, enabled in
                    if enabled { deriveTaprootAddress() }
                    configService.save()
                }

                if configService.config.showBitcoinWallet {
                    if taprootAddress.isEmpty {
                        HStack {
                            Spacer()
                            ProgressView().controlSize(.small)
                            Spacer()
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            if let qrImage = generateQRCode(from: taprootAddress) {
                                HStack {
                                    Spacer()
                                    Image(platformImage: qrImage)
                                        .interpolation(.none)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 160, height: 160)
                                        .cornerRadius(8)
                                    Spacer()
                                }
                            }

                            Text(taprootAddress)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(2)
                                .minimumScaleFactor(0.7)

                            Button {
                                copyAddress()
                            } label: {
                                Label(
                                    addressCopied ? "Copied!" : "Copy Address",
                                    systemImage: addressCopied ? "checkmark" : "doc.on.doc"
                                )
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(.vertical, 4)
                    }

                    Divider()
                        .padding(.vertical, 8)

                    Button(action: { showSweepDisclaimer = true }) {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.up.right.circle.fill")
                            Text("Sweep Wallet")
                                .font(.appSystem(size: 15, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.orange)
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Bitcoin")
            } footer: {
                Text("Your Nostr key is a valid Bitcoin Taproot key. This address is derived deterministically from your npub via BIP-341 — no separate seed phrase needed.")
            }
        }
        .groupedFormStyleCompat()
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(isPresented: $showSweepDisclaimer) {
            BitcoinSweepDisclaimerView(onDismiss: { showSweepDisclaimer = false })
                .environmentObject(configService)
        }
        .onAppear {
            if !configService.config.nwcURI.isEmpty {
                fetchBalance()
            }
            if configService.config.showBitcoinWallet && taprootAddress.isEmpty {
                deriveTaprootAddress()
            }
        }
        .onChange(of: configService.config.nwcURI) { _, _ in
            balance = nil
            balanceError = nil
        }
    }

    private func fetchBalance() {
        guard !configService.config.nwcURI.isEmpty else { return }
        isFetchingBalance = true
        balanceError = nil
        Task {
            do {
                let msat = try await NWCService.getBalance()
                await MainActor.run {
                    self.balance = msat
                    self.isFetchingBalance = false
                }
            } catch {
                await MainActor.run {
                    self.balanceError = error.localizedDescription
                    self.isFetchingBalance = false
                }
            }
        }
    }

    private func deriveTaprootAddress() {
        let npub = configService.config.ownerNpub.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !npub.isEmpty,
              let decoded = Bech32.decode(npub),
              decoded.hrp == "npub" else { return }
        let hexPubKey = decoded.hexString
        if let cAddr = hexPubKey.withCString({ DeriveTaprootAddressC(UnsafeMutablePointer(mutating: $0)) }) {
            taprootAddress = String(cString: cAddr)
        }
    }

    private func copyAddress() {
        guard !taprootAddress.isEmpty else { return }
        #if os(iOS)
        UIPasteboard.general.string = taprootAddress
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(taprootAddress, forType: .string)
        #endif
        addressCopied = true
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run { addressCopied = false }
        }
    }

    private func generateQRCode(from string: String) -> PlatformImage? {
        guard let data = string.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        #if os(iOS)
        return UIImage(cgImage: cgImage)
        #else
        return NSImage(cgImage: cgImage, size: scaled.extent.size)
        #endif
    }
}

struct AppearanceSettingsView: View {
    @EnvironmentObject var configService: ConfigService
    @State private var showEmojiPicker = false

    var body: some View {
        Form {
            // Accent Theme picker removed — the app ships a single appearance
            // (OLED black with the orange accent), so there is nothing to choose.

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Text Size")
                        Spacer()
                        Text(String(format: "%.0f%%", configService.config.textSizeScale * 100))
                            .foregroundColor(.secondary)
                    }
                    
                    Slider(
                        value: $configService.config.textSizeScale,
                        in: 0.8...1.6,
                        step: 0.1
                    ) {
                        Text("Text Size")
                    } minimumValueLabel: {
                        Text("A").font(.appSystem(size: 12))
                    } maximumValueLabel: {
                        Text("A").font(.appSystem(size: 20))
                    }
                    .onChange(of: configService.config.textSizeScale) { _, _ in
                        configService.save()
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Text Accessibility")
            } footer: {
                Text("Adjust the size of text across the app — feeds, note details, profiles, DM inbox, message threads, and compose editors.")
            }

            // OLED black is the app's only appearance now, so there is nothing
            // left to toggle here — the section was removed along with the
            // colour-theme picker below.

            #if os(iOS)
            Section {
                Toggle(isOn: $configService.config.disableTabBarAnimation) {
                    Label("Disable Tab Bar Animation", systemImage: "rectangle.bottombar.fill")
                }
                .onChange(of: configService.config.disableTabBarAnimation) { _, _ in
                    configService.save()
                }
            } header: {
                Text("Tab Bar")
            } footer: {
                Text("Keep the bottom tab bar fully expanded at all times. When off, the bar shrinks and hides as you scroll.")
            }
            #endif

            Section {
                Toggle(isOn: $configService.config.zapsOnlyMode) {
                    Label("Zaps Only Mode", systemImage: "bolt.fill")
                }
                .onChange(of: configService.config.zapsOnlyMode) { _, _ in
                    configService.save()
                }
            } header: {
                Text("Engagement")
            } footer: {
                Text("Remove likes and reactions from the app entirely. Zaps become the only way to engage with notes and the primary source of relay notifications.")
            }

            if !configService.config.zapsOnlyMode {
                Section {
                    Button(action: {
                        showEmojiPicker = true
                    }) {
                        HStack {
                            Label("Default Reaction", systemImage: "heart.fill")
                                .foregroundColor(.primary)
                            Spacer()
                            Text(configService.config.defaultReactionEmoji)
                                .font(.appSystem(size: 24))
                            Image(systemName: "chevron.right")
                                .font(.appSystem(size: 12))
                                .foregroundColor(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                } header: {
                    Text("Reactions")
                } footer: {
                    Text("Choose your default reaction emoji. This emoji will be used when you tap the heart button on a note.")
                }
            }

            #if os(iOS)
            Section {
                AppIconPicker(selectedIcon: $configService.config.appIcon) { iconName in
                    configService.save()
                    setAppIcon(iconName)
                }
            } header: {
                Text("App Icon")
            } footer: {
                Text("Choose your app icon. Changes take effect immediately.")
            }
            #endif
        }
        .groupedFormStyleCompat()
        .sheet(isPresented: $showEmojiPicker) {
            EmojiPickerView { emoji in
                configService.config.defaultReactionEmoji = emoji
                configService.save()
                showEmojiPicker = false
            }
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    #if os(iOS)
    private func setAppIcon(_ iconName: String) {
        let iconToSet = iconName == "Default" ? nil : iconName

        guard UIApplication.shared.supportsAlternateIcons else {
            print("Alternate icons not supported")
            return
        }

        UIApplication.shared.setAlternateIconName(iconToSet) { error in
            if let error = error {
                print("Error setting alternate icon: \(error.localizedDescription)")
            }
        }
    }
    #endif

    
}
 
#if os(macOS)
#endif

#if os(macOS)
/// macOS settings page for configuring the relay domain, port, and Cloudflare tunnel.
struct MacRelayDomainSettingsView: View {
    @EnvironmentObject var configService: ConfigService

    var body: some View {
        Form {
            // MARK: - Domain
            Section {
                TextField("relay.yourdomain.com", text: $configService.config.relayURL)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)

                if !configService.config.sanitizedRelayURL.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.havenOnline)
                                .font(.appCaption)
                            Text("wss://\(configService.config.sanitizedRelayURL)")
                                .font(.appSystem(size: 12, design: .monospaced))
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                        }
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.havenOnline)
                                .font(.appCaption)
                            Text("https://\(configService.config.sanitizedRelayURL)")
                                .font(.appSystem(size: 12, design: .monospaced))
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.top, 4)
                }
            } header: {
                Text("Relay Domain")
            } footer: {
                Text("Enter a domain to make your relay publicly accessible. Leave blank for local-only. Accepts any format (https://, wss://, or bare domain).")
            }

            // MARK: - Port
            Section {
                HStack {
                    Text("Port")
                    Spacer()
                    TextField("3355", value: $configService.config.relayPort, formatter: NumberFormatter.noSeparator)
                        .frame(width: 80)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                }
            } header: {
                Text("Network")
            } footer: {
                Text("The relay listens on all network interfaces (0.0.0.0). Default port is 3355.")
            }

            // MARK: - Cloudflare Tunnel Instructions
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    instructionStep(1, "Install cloudflared",
                        "brew install cloudflared")
                    instructionStep(2, "Authenticate with Cloudflare",
                        "cloudflared tunnel login")
                    instructionStep(3, "Create a tunnel",
                        "cloudflared tunnel create haven")
                    instructionStep(4, "Route your domain to the tunnel",
                        "cloudflared tunnel route dns haven \(configService.config.sanitizedRelayURL.isEmpty ? "relay.yourdomain.com" : configService.config.sanitizedRelayURL)")
                    instructionStep(5, "Run the tunnel",
                        "cloudflared tunnel run --url http://localhost:\(configService.config.relayPort) haven")
                }
                .padding(.vertical, 4)
            } header: {
                Text("Cloudflare Tunnel Setup")
            } footer: {
                Text("To keep the tunnel running in the background, use `brew services start cloudflared` or add it to your login items.")
            }
        }
        .groupedFormStyleCompat()
    }

    private func instructionStep(_ number: Int, _ title: String, _ command: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(number). \(title)")
                .font(.appSubheadline.bold())
            HStack {
                Text(command)
                    .font(.appSystem(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05))
                    .cornerRadius(4)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.appSystem(size: 11))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Copy to clipboard")
            }
        }
    }
}
#endif

#if os(iOS)
/// iOS-only settings page for the always-on Mac Nostr Vault relay.
/// A single https:// URL entry derives the WSS address for sync and optionally
/// populates Import relays, Blastr relays, and Blossom mirrors automatically.
struct MacRelaySettingsView: View {
    @EnvironmentObject var configService: ConfigService
    @StateObject private var macSyncService = MacRelaySyncService.shared

    /// Track computed URLs from the previous save so we can migrate array entries on URL change.
    @State private var prevWssURL: String = ""
    @State private var prevHttpsURL: String = ""

    var body: some View {
        Form {
            // ── URL Input ──────────────────────────────────────────────
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("https://relay.example.com", text: $configService.config.macRelayURL)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .padding(10)
                        .background(Color.platformControlBackground)
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                        )

                    Text("Enter your Mac relay in any format — https://, wss://, or bare domain. All derived addresses below are computed automatically.")
                        .font(.appCaption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            } header: {
                HStack(spacing: 6) {
                    Image(systemName: "desktopcomputer")
                    Text("Mac Relay URL")
                }
            }

            // ── Derived Addresses ──────────────────────────────────────
            let wssURL = configService.config.macRelayWssURL
            let httpsURL = configService.config.macRelayHttpsURL

            if !wssURL.isEmpty {
                Section {
                    // Always-on: Feed Relays
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.havenOnline)
                            .font(.appBody)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Feed Relays")
                                .font(.appSubheadline.bold())
                            Text(wssURL)
                                .font(.appSystem(size: 12, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.vertical, 2)

                    // Always-on: Import Relays
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.havenOnline)
                            .font(.appBody)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Import Relays")
                                .font(.appSubheadline.bold())
                            Text(wssURL)
                                .font(.appSystem(size: 12, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.vertical, 2)

                    // Always-on: Blastr Relays
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.havenOnline)
                            .font(.appBody)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Blastr Relays")
                                .font(.appSubheadline.bold())
                            Text(wssURL)
                                .font(.appSystem(size: 12, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.vertical, 2)

                    // Always-on: Blossom Mirror
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.havenOnline)
                            .font(.appBody)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Blossom Mirror")
                                .font(.appSubheadline.bold())
                            Text(httpsURL)
                                .font(.appSystem(size: 12, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.vertical, 2)
                } header: {
                    Text("Derived Addresses")
                } footer: {
                    Text("Your Mac relay is automatically included in all relay lists. Events sync continuously via standard Nostr subscriptions while the app is open, and via the catch-up sync below otherwise.")
                }

                // ── Sync Controls ──────────────────────────────────────
                Section {
                    if macSyncService.isSyncing {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(macSyncService.syncStatus)
                                .font(.appCaption)
                                .foregroundColor(.secondary)
                        }
                    } else if !macSyncService.syncStatus.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: macSyncService.notesSynced > 0 ? "checkmark.circle.fill" : "info.circle.fill")
                                .foregroundColor(macSyncService.notesSynced > 0 ? .havenOnline : .blue)
                                .font(.appCaption)
                            Text(macSyncService.syncStatus)
                                .font(.appCaption)
                                .foregroundColor(.secondary)
                        }
                    }

                    if let lastSync = macSyncService.lastSyncDate {
                        HStack(spacing: 6) {
                            Image(systemName: "clock")
                                .font(.appCaption)
                                .foregroundColor(.secondary)
                            Text("Last sync \(lastSync, style: .relative) ago")
                                .font(.appCaption2)
                                .foregroundColor(.secondary)
                        }
                    }

                    HStack(spacing: 12) {
                        Button(action: { macSyncService.forceSync() }) {
                            Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.havenPurple)
                        .disabled(macSyncService.isSyncing)

                        Button(action: {
                            macSyncService.resetSync()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                macSyncService.forceSync()
                            }
                        }) {
                            Label("Full Resync", systemImage: "arrow.clockwise")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(Color.havenPurple)
                        .disabled(macSyncService.isSyncing)
                    }
                } header: {
                    Text("Sync")
                } footer: {
                    Text("Sync Now fetches notes missed since the last sync — this is what runs automatically on app foreground and in the background refresh window. Full Resync resets the timestamp and re-fetches everything from the beginning.")
                }
            }
        }
        .groupedFormStyleCompat()
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            prevWssURL = configService.config.macRelayWssURL
            prevHttpsURL = configService.config.macRelayHttpsURL
        }
        .onChange(of: configService.config.macRelayURL) { _, _ in
            migrateRelayURLs()
        }
    }

    // MARK: - URL change migration

    /// When the Mac relay URL changes, update any array entries that were derived from the old URL
    /// so Feed relays, Import relays, Blastr relays, and Blossom Mirrors stay in sync automatically.
    private func migrateRelayURLs() {
        let newWss = configService.config.macRelayWssURL
        let newHttps = configService.config.macRelayHttpsURL

        if !prevWssURL.isEmpty && prevWssURL != newWss {
            configService.config.feedRelays = configService.config.feedRelays
                .map { $0 == prevWssURL ? newWss : $0 }
                .filter { !$0.isEmpty }
            configService.config.importSeedRelays = configService.config.importSeedRelays
                .map { $0 == prevWssURL ? newWss : $0 }
                .filter { !$0.isEmpty }
            configService.config.blastrRelays = configService.config.blastrRelays
                .map { $0 == prevWssURL ? newWss : $0 }
                .filter { !$0.isEmpty }
        }

        if !prevHttpsURL.isEmpty && prevHttpsURL != newHttps {
            configService.config.blossomMirrors = configService.config.blossomMirrors
                .map { $0 == prevHttpsURL ? newHttps : $0 }
                .filter { !$0.isEmpty }
        }

        prevWssURL = newWss
        prevHttpsURL = newHttps
    }
}
#endif

struct BlossomSettingsView: View {
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var relayManager: RelayProcessManager
    @ObservedObject private var mirrorService = MirrorService.shared

    @State private var newMirrorURL = ""
    #if os(macOS)
    @StateObject private var fipsDetection = FIPSDetectionService()
    #else
    @State private var isVPNActive = false
    #endif
    
    var body: some View {
        Form {
            // Section 1: Auto-Applied Blossom Server
            Section {
                let macHttps = configService.config.macRelayHttpsURL
                if !macHttps.isEmpty {
                    HStack(spacing: 12) {
                        Image(systemName: "desktopcomputer")
                            .font(.appSystem(size: 18))
                            .foregroundColor(.havenOnline)
                            .frame(width: 24, height: 24)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                Text("Mac Relay Sync Server")
                                    .font(.appSubheadline.bold())
                                    .foregroundColor(.white)
                                
                                Text("Active")
                                    .font(.appSystem(size: 9, weight: .bold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.havenOnline.opacity(0.15))
                                    .foregroundColor(.havenOnline)
                                    .cornerRadius(4)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 4)
                                            .stroke(Color.havenOnline.opacity(0.3), lineWidth: 1)
                                    )
                            }
                            Text(macHttps)
                                .font(.appSystem(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                } else {
                    HStack(spacing: 12) {
                        Image(systemName: "desktopcomputer.badge.warning")
                            .font(.appSystem(size: 18))
                            .foregroundColor(.secondary)
                            .frame(width: 24, height: 24)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("No Mac Sync Relay Configured")
                                .font(.appSubheadline.bold())
                                .foregroundColor(.secondary)
                            Text("Configure your Mac relay in the 'Mac Relay' tab to automatically apply it here.")
                                .font(.appCaption)
                                .foregroundColor(.secondary.opacity(0.7))
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("Auto-Applied Blossom Servers")
            } footer: {
                Text("Your personal Mac Sync Relay is automatically applied as a Blossom mirror. No manual setup required.")
            }
            
            // Section 2: Additional Blossom Servers (Mirrors)
            Section {
                let mirrors = configService.config.blossomMirrors
                if mirrors.isEmpty {
                    Text("No additional Blossom servers configured.")
                        .foregroundColor(.secondary)
                        .font(.appSubheadline)
                        .padding(.vertical, 4)
                } else {
                    ForEach(mirrors, id: \.self) { url in
                        HStack {
                            Image(systemName: "server.rack")
                                .font(.appSystem(size: 14))
                                .foregroundColor(.havenPurple)
                            Text(url)
                                .font(.appSystem(size: 12, design: .monospaced))
                                .foregroundColor(.white)
                            Spacer()
                            Button(action: {
                                configService.config.blossomMirrors.removeAll(where: { $0 == url })
                                configService.save()
                                NostrService.shared.publishServerList()
                            }) {
                                Image(systemName: "minus.circle")
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 2)
                    }
                }
                
                // Add mirror input
                HStack(spacing: 8) {
                    TextField("https://blossom.example.com", text: $newMirrorURL)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                        .onSubmit {
                            addMirror()
                        }
                    
                    Button(action: addMirror) {
                        Image(systemName: "plus.circle.fill")
                            .foregroundColor(.havenOnline)
                            .font(.appTitle3)
                    }
                    .buttonStyle(.plain)
                    .disabled(newMirrorURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.top, 4)
            } header: {
                Text("Additional Blossom Servers")
            } footer: {
                Text("Add external Blossom servers. The relay will fetch from and mirror your media to these servers.")
            }
            
            // Section 3: Media Sync & Mirroring
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Mirror from Servers")
                            .font(.appBody)
                            .foregroundColor(.white)
                        Text("Download your media from external Blossom mirrors to local storage")
                            .font(.appCaption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(action: {
                        mirrorService.runMirror(configService: configService, nostrService: NostrService.shared)
                    }) {
                        HStack(spacing: 6) {
                            if mirrorService.state == .mirroring {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "arrow.down.circle")
                            }
                            if let progress = mirrorService.progress, mirrorService.state == .mirroring {
                                Text("\(progress.completed)/\(progress.total)")
                            } else {
                                Text("Mirror Now")
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.havenPurple.opacity(mirrorService.state == .mirroring ? 0.3 : 1.0))
                        .foregroundColor(.white)
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .disabled(mirrorService.state == .mirroring || configService.config.activeBlossomMirrors.isEmpty)
                }
                
                Toggle(isOn: Binding(
                    get: { configService.config.autoMirrorMedia },
                    set: { newValue in
                        configService.config.autoMirrorMedia = newValue
                        configService.save()
                    }
                )) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Auto-Mirror Media")
                            .font(.appBody)
                            .foregroundColor(.white)
                        Text("Automatically download your media from mirrors when the relay starts")
                            .font(.appCaption)
                            .foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("Media Mirroring")
            } footer: {
                Text("Downloads your own Blossom media from active servers to your local relay for offline access.")
            }

            // Section 4: FIPS
            #if os(macOS)
            Section {
                HStack(spacing: 8) {
                    Circle()
                        .fill(fipsStatusColor)
                        .frame(width: 8, height: 8)
                    Text(fipsStatusText)
                        .font(.appCaption)
                        .foregroundColor(.secondary)
                }

                Toggle(isOn: Binding(
                    get: { configService.config.fipsPublishEnabled },
                    set: { newValue in
                        configService.config.fipsPublishEnabled = newValue
                        configService.save()
                        NostrService.shared.publishServerList(fipsDetectedNpub: fipsDetection.detectedNpub)
                    }
                )) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Publish .fips Blossom Address")
                            .font(.appBody)
                            .foregroundColor(.white)
                        Text("Advertise your FIPS address in your Blossom server list (kind 10063)")
                            .font(.appCaption)
                            .foregroundColor(.secondary)
                    }
                }

                if configService.config.fipsPublishEnabled {
                    Picker("Address Source", selection: Binding(
                        get: { configService.config.fipsAddressSource },
                        set: { newValue in
                            configService.config.fipsAddressSource = newValue
                            configService.save()
                            NostrService.shared.publishServerList(fipsDetectedNpub: fipsDetection.detectedNpub)
                        }
                    )) {
                        Text("My Nostr npub").tag("owner")
                        if fipsDetection.detectedNpub != nil {
                            Text("Detected (nostr-vpn)").tag("detected")
                        }
                        Text("Custom").tag("custom")
                    }

                    if configService.config.fipsAddressSource == "custom" {
                        TextField("npub1...", text: Binding(
                            get: { configService.config.fipsCustomNpub },
                            set: { newValue in
                                configService.config.fipsCustomNpub = newValue
                                configService.save()
                            }
                        ))
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                        .font(.appSystem(size: 12, design: .monospaced))
                    }

                    if let url = configService.config.fipsBlossomURL(detectedNpub: fipsDetection.detectedNpub) {
                        HStack {
                            Text(url)
                                .font(.appSystem(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(1)
                            Spacer()
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(url, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.appSystem(size: 12))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Text("A FIPS transport (e.g. nostr-vpn) must be running to make this address reachable.")
                        .font(.appCaption2)
                        .foregroundColor(.secondary.opacity(0.7))
                }
            } header: {
                Text("FIPS")
            } footer: {
                Text("Expose your Blossom server over the FIPS overlay network. Clients with a FIPS transport can reach your media without a public IP or domain.")
            }
            #else
            Section {
                HStack(spacing: 8) {
                    Circle()
                        .fill(isVPNActive ? Color.havenOnline : Color.gray)
                        .frame(width: 8, height: 8)
                    Text(isVPNActive ? "VPN active" : "No VPN detected")
                        .font(.appCaption)
                        .foregroundColor(.secondary)
                }
                Text("To access media from .fips servers, enable your FIPS VPN (e.g. nostr-vpn) and add the server's .fips address as an Additional Server above.")
                    .font(.appCaption)
                    .foregroundColor(.secondary)
            } header: {
                Text("FIPS")
            }
            #endif
        }
        .groupedFormStyleCompat()
        #if os(macOS)
        .onAppear { fipsDetection.startPolling() }
        .onDisappear { fipsDetection.stopPolling() }
        #else
        .onAppear { isVPNActive = Self.checkVPNActive() }
        #endif
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    #if os(macOS)
    private var fipsStatusColor: Color {
        switch fipsDetection.status {
        case .running: return .havenOnline
        case .installed, .stale: return .yellow
        case .notInstalled: return .gray
        }
    }

    private var fipsStatusText: String {
        switch fipsDetection.status {
        case .running: return "FIPS transport active"
        case .stale: return "FIPS transport not responding"
        case .installed: return "FIPS transport installed but not running"
        case .notInstalled: return "No FIPS transport detected"
        }
    }
    #else
    static func checkVPNActive() -> Bool {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0 else { return false }
        defer { freeifaddrs(addrs) }
        var ptr = addrs
        while let addr = ptr {
            let name = String(cString: addr.pointee.ifa_name)
            if name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp") {
                return true
            }
            ptr = addr.pointee.ifa_next
        }
        return false
    }
    #endif
    
    private func addMirror() {
        var trimmed = newMirrorURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            if !trimmed.lowercased().hasPrefix("https://") && !trimmed.lowercased().hasPrefix("http://") {
                trimmed = "https://" + trimmed
            }
            while trimmed.hasSuffix("/") {
                trimmed = String(trimmed.dropLast())
            }
            if !configService.config.blossomMirrors.contains(trimmed) {
                configService.config.blossomMirrors.append(trimmed)
                configService.save()
                NostrService.shared.publishServerList()
                newMirrorURL = ""
            }
        }
    }
}

#if os(iOS)
// MARK: - App Icon Selection

enum AppIconOption: String, CaseIterable, Identifiable {
    case `default` = "Default"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .default: return "Vault (Default)"
        }
    }

    var iconName: String? {
        switch self {
        case .default: return nil  // nil means the primary app icon
        }
    }

    var previewImageName: String {
        "AppIcon"  // All variants use the same preview for now
    }
}

struct AppIconPicker: View {
    @Binding var selectedIcon: String
    let onChange: (String) -> Void

    var body: some View {
        ForEach(AppIconOption.allCases) { option in
            Button(action: {
                selectedIcon = option.rawValue
                onChange(option.rawValue)
            }) {
                HStack(spacing: 12) {
                    // App icon preview
                    Image("AppIcon")
                        .resizable()
                        .frame(width: 60, height: 60)
                        .cornerRadius(13.5)
                        .overlay(
                            RoundedRectangle(cornerRadius: 13.5)
                                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                        )

                    Text(option.displayName)
                        .foregroundColor(.primary)

                    Spacer()

                    if selectedIcon == option.rawValue {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.havenPurple)
                    }
                }
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
        }
    }
}
#endif

// RelayListEditor and LogsView moved to separate files

