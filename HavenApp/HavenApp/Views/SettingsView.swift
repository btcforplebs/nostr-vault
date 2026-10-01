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
    
    enum SettingsTab: String, CaseIterable, Identifiable {
        case accounts = "Accounts & Keys"
        case blocked = "Blocked"
        case followingBackup = "Following Backup"
        case wallet = "Wallet"
        case feed = "Feed"
        case appearance = "Appearance"
        case media = "Media & Cache"
        case pushNotifications = "Notifications"
        case dm = "DM Relays"
        case blastr = "Broadcast"
        case blossom = "Media Servers"
        case macRelay = "Sync with Mac"
        case relayAccess = "Who Can Reach You"
        case importNotes = "Import Notes"
        case backup = "Backup & Restore"
        case startup = "Startup"
        case proofOfWork = "Proof of Work"
        case advanced = "Database & Reset"
        case logs = "Logs"

        var id: String { self.rawValue }

        var title: String {
            switch self {
            case .macRelay:
                #if os(macOS)
                return "Domain & Port"
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
            case .followingBackup: return "person.crop.circle.badge.clock"
            case .wallet: return "bitcoinsign.circle"
            case .feed: return "newspaper"
            case .appearance: return "paintpalette"
            case .media: return "photo.on.rectangle"
            case .pushNotifications: return "bell.badge"
            case .dm: return "bubble.left.and.bubble.right"
            case .blastr: return "paperplane"
            case .blossom: return "server.rack"
            case .macRelay:
                #if os(macOS)
                return "globe"
                #else
                return "desktopcomputer"
                #endif
            case .relayAccess: return "person.2.badge.gearshape"
            case .importNotes: return "square.and.arrow.down"
            case .backup: return "externaldrive.fill"
            case .startup: return "power"
            case .proofOfWork: return "hammer.fill"
            case .advanced: return "gearshape.2"
            case .logs: return "list.bullet.rectangle"
            }
        }
    }

    /// The settings grouped by what someone is trying to do, not by which
    /// process owns the value. Both the iPhone list and the Mac sidebar read
    /// this, so the two can't drift into different orders.
    ///
    /// Startup is a page on the Mac (auto-start plus launch at login) but a
    /// single inline switch on iPhone, where a page for one toggle is a
    /// dead end.
    static var groups: [(title: String, tabs: [SettingsTab])] {
        #if os(macOS)
        let relayTabs: [SettingsTab] = [.macRelay, .relayAccess, .importNotes, .backup, .startup]
        #else
        let relayTabs: [SettingsTab] = [.macRelay, .relayAccess, .importNotes, .backup]
        #endif
        return [
            ("Account", [.accounts, .blocked, .followingBackup, .wallet]),
            ("Feed & Display", [.feed, .appearance, .media]),
            ("Notifications", [.pushNotifications]),
            ("Sharing", [.dm, .blastr, .blossom]),
            ("Your Vault Relay", relayTabs),
            ("Advanced", [.proofOfWork, .advanced, .logs]),
        ]
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
                    commitSave()
                }
            }
        }
        .onDisappear {
            // Leaving mid-debounce must not drop the change or its restart.
            if saveTask != nil {
                saveTask?.cancel()
                commitSave()
            }
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
            // Header inside settings sidebar. Suppressed when embedded: the host
            // window's own sidebar already has a row labelled "Settings" selected
            // immediately to the left of this one, and the detail pane's header
            // names the open tab, so this drew a third "Settings" in one window.
            if !isEmbedded {
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
            } else {
                Color.clear.frame(height: 12)
            }

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
                    ForEach(Self.groups, id: \.title) { group in
                        settingsSidebarSection(group.title, items: group.tabs)
                    }
                }
                .padding(.horizontal, 8)
            }
            
            Spacer()
            
            Divider()
                .background(Color.platformSeparator)
            
            // Restart status / About in sidebar bottom
            VStack(spacing: 8) {
                if relayManager.isApplyingConfig {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Restarting relay…")
                            .font(.appSystem(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
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
        // Embedded, this column sits directly against the host window's own 220pt
        // sidebar, which paints this exact colour. Two identical slabs read as one
        // 440pt band of chrome with a rule down the middle; on the window
        // background it reads as the tab list of the pane it belongs to.
        .background(isEmbedded ? Color.platformWindowBackground : Color(red: 0.1, green: 0.1, blue: 0.13))
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
                RelayStatusCard()
                    .padding(.horizontal)
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)

            ForEach(Self.groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.tabs) { tab in
                        tabLink(tab)
                    }
                    if group.title == "Your Vault Relay" {
                        // One switch, so it lives here rather than behind a
                        // page of its own (the Mac has a Startup page).
                        Toggle(isOn: $configService.config.autoStartRelay) {
                            Label {
                                Text("Start Relay Automatically")
                                    .font(.appBody)
                                    .settingInfo(.relayAutoStart)
                            } icon: {
                                settingsIcon(SettingsTab.startup.icon, color: .green)
                            }
                        }
                    }
                }
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
                settingsIcon(tab.icon, color: iconBackgroundColor(for: tab))
            }
        }
    }

    private func settingsIcon(_ systemName: String, color: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(color)
                .frame(width: 28, height: 28)
            Image(systemName: systemName)
                .font(.appSystem(size: 14, weight: .semibold))
                .foregroundColor(.white)
        }
    }

    private func iconBackgroundColor(for tab: SettingsTab) -> Color {
        switch tab {
        case .accounts: return .blue
        case .blocked: return .red
        case .appearance: return .purple
        case .feed: return .pink
        case .media: return .indigo
        case .dm: return .mint
        case .pushNotifications: return .red
        case .importNotes: return .orange
        case .relayAccess: return .blue
        case .backup: return .indigo
        case .startup: return .green
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

    /// Saves, then lets the relay manager restart the relay if (and only if)
    /// the save changed something the relay reads at start.
    private func commitSave() {
        saveTask = nil
        configService.save()
        relayManager.applySavedConfig(configService.config)
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
            case .media: MediaSettingsView()
            case .relayAccess: RelayAccessSettingsView()
            case .startup: StartupSettingsView()
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
    
}

/// The first thing on the Settings screen: whether this device's Vault relay
/// is running and where it answers. A saved change the relay reads at start
/// restarts it automatically; the card shows "Restarting…" meanwhile.
///
/// This replaces a purple "Restart Required" banner that appeared from
/// nowhere and never said which relay it meant — people with a Mac relay
/// assumed it meant that one.
struct RelayStatusCard: View {
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var relayManager: RelayProcessManager

    private enum Status {
        case running, starting, restarting, stopped

        var label: String {
            switch self {
            case .running: return "Running"
            case .starting: return "Starting…"
            case .restarting: return "Restarting…"
            case .stopped: return "Stopped"
            }
        }

        var color: Color {
            switch self {
            case .running: return .havenOnline
            case .starting, .restarting: return .orange
            case .stopped: return .red
            }
        }
    }

    private var status: Status {
        if relayManager.isApplyingConfig { return .restarting }
        if relayManager.isBooting { return .starting }
        return relayManager.isRunning ? .running : .stopped
    }

    /// The public domain when one is set (Mac), otherwise the loopback
    /// address the app itself talks to.
    private var address: String {
        let domain = configService.config.sanitizedRelayURL
        if !domain.isEmpty && !configService.config.isLocal {
            return "wss://\(domain)"
        }
        return "ws://127.0.0.1:\(configService.config.relayPort)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.havenPurple.opacity(0.18))
                        .frame(width: 44, height: 44)
                    Image(systemName: "externaldrive.connected.to.line.below")
                        .font(.appSystem(size: 20, weight: .semibold))
                        .foregroundColor(.havenPurple)
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Your Vault Relay")
                        .font(.appHeadline)
                        .settingInfo(.relayStatus)
                    Text(address)
                        .font(.appSystem(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

                Spacer(minLength: 8)

                HStack(spacing: 6) {
                    Circle()
                        .fill(status.color)
                        .frame(width: 8, height: 8)
                    Text(status.label)
                        .font(.appSubheadline.weight(.semibold))
                        .foregroundColor(status.color)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Relay \(status.label)")
            }

            if status == .stopped {
                Button {
                    relayManager.startRelay(config: configService.config)
                } label: {
                    Label("Start Relay", systemImage: "play.fill")
                        .font(.appSubheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.havenOnline.opacity(0.18))
                        .foregroundColor(.havenOnline)
                        .cornerRadius(10)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.platformControlBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
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
                Text("Accounts").settingInfo(.accountAccounts)
            } footer: {
                #if os(iOS)
                Text("Tap an account to manage its keys. Swipe to remove.")
                #else
                Text("Click an account to manage its keys or remove it.")
                #endif
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
            AvatarView(url: profile?.pictureURL, pubkey: hex, size: 38)
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
        NavigationStack {
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
                        Text("Sign With").settingInfo(.accountSigning)
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
                        .settingInfo(.accountRevealKey)

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
                        Toggle(isOn: Binding(
                            get: { configService.config.publishRelayListPerAccount[npub] ?? false },
                            set: { enabled in
                                configService.config.publishRelayListPerAccount[npub] = enabled
                                configService.save()
                                if enabled {
                                    NostrService.shared.publishRelayList(forNpub: npub)
                                }
                            }
                        )) {
                            Text("Publish Inbox Relay").settingInfo(.accountPublishInbox)
                        }
                    } header: {
                        Text("Relay List")
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
            AvatarView(url: profile?.pictureURL, pubkey: hex, size: 48)

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
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Text("Connect Remote Signer")
                    .font(.appHeadline)
                Spacer()
                Button("Connect") { connectBunker() }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.havenPurple)
                    .disabled(bunkerURI.isEmpty || isConnecting)
                    .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                SignInWithClaveView { request, signerPubkey in
                    try await pairWithClave(request, signerPubkey: signerPubkey)
                }
                .tint(Color.havenPurple)

                Divider()

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
        NavigationStack {
            Form {
                Section {
                    SignInWithClaveView { request, signerPubkey in
                        try await pairWithClave(request, signerPubkey: signerPubkey)
                    }
                    .tint(Color.havenPurple)
                } footer: {
                    Text("Or paste a bunker link from any signer app below.")
                }

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
                    if isConnecting {
                        Text("Approve the connection in your signer app")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
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

    /// Finishes a "Sign in with Clave" pairing for this account: stored like a
    /// pasted bunker link (with the pairing's own client key), then connected.
    private func pairWithClave(_ request: NIP46Service.NostrConnectRequest, signerPubkey: String) async throws {
        let bunkerConfig = AccountBunkerConfig(
            bunkerURI: NIP46Service.bunkerURI(signerPubkey: signerPubkey, relays: request.relays),
            signerPubkey: signerPubkey,
            relayURL: request.relays.first ?? "",
            secret: "",
            clientSecretKey: request.clientSecretKey,
            clientPubkey: request.clientPubkey
        )
        configService.setBunkerConfig(bunkerConfig, forNpub: npub)
        configService.setSigningMode("nip46", forNpub: npub)
        let activeNpub = configService.config.activeAccountNpub.isEmpty ? configService.config.ownerNpub : configService.config.activeAccountNpub
        do {
            if npub == activeNpub {
                try await NIP46Service.shared.waitForConnection()
            }
        } catch {
            configService.removeBunkerConfig(forNpub: npub)
            throw error
        }
        performDismiss()
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

                // If this is the active account, setSigningMode already started
                // the connect: wait on that one handshake rather than starting a
                // second that would re-send the single-use secret.
                let activeNpub = configService.config.activeAccountNpub.isEmpty ? configService.config.ownerNpub : configService.config.activeAccountNpub
                if npub == activeNpub {
                    try await NIP46Service.shared.waitForConnection()
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
                .keyboardShortcut(.cancelAction)
                
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
                .keyboardShortcut(.defaultAction)
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
        NavigationStack {
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
                .keyboardShortcut(.cancelAction)
                
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
                .keyboardShortcut(.defaultAction)
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
        NavigationStack {
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
                .keyboardShortcut(.cancelAction)

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
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Done") {
                        performDismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.havenPurple)
                    .keyboardShortcut(.defaultAction)
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
        NavigationStack {
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
                Text("Block Someone").settingInfo(.accountBlocked)
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
                            AvatarView(url: profile?.pictureURL, pubkey: hex, size: 32)
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
                            AvatarView(url: profile?.pictureURL, pubkey: hex, size: 32)
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
                Text("Slowed Down").settingInfo(.accountSlowed)
            } footer: {
                Text("Tap a name in the feed to slow someone down.")
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
                HStack {
                    Text("Engine")
                        .settingInfo(.advDatabase)
                    Spacer()
                    Text(configService.config.dbEngine == "badger" ? "BadgerDB" : "LMDB")
                        .foregroundColor(.secondary)
                }

                #if os(macOS)
                HStack {
                    Text("Media Folder")
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
                    .help("Show in Finder")
                }
                #endif
            } header: {
                Text("Database")
            }

            Section {
                Button(role: .destructive) {
                    showResetConfirmation = true
                } label: {
                    Label("Factory Reset", systemImage: "trash")
                        .foregroundColor(.red)
                }
                .settingInfo(.advFactoryReset)
            } header: {
                Text("Danger Zone")
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

/// How media is played and kept on this device. App-side only: none of this
/// reaches the relay, which is why it no longer sits in Advanced next to the
/// relay's database.
struct MediaSettingsView: View {
    @EnvironmentObject var configService: ConfigService
    @State private var cacheBytes: Int64? = nil
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $configService.config.autoplayVideos) {
                    Text("Autoplay Videos").settingInfo(.mediaAutoplay)
                }
                Toggle(isOn: $configService.config.prefetchProfilePictures) {
                    Text("Prefetch Profile Pictures").settingInfo(.mediaPrefetchAvatars)
                }
            } header: {
                Text("Playback")
            }

            Section {
                Toggle(isOn: $configService.config.disableMediaCache) {
                    Text("Disable Media Cache").settingInfo(.mediaDisableCache)
                }
                Picker(selection: $configService.config.cacheTTLDays) {
                    Text("1 day").tag(1)
                    Text("3 days").tag(3)
                    Text("7 days").tag(7)
                    Text("14 days").tag(14)
                    Text("30 days").tag(30)
                    Text("Never").tag(0)
                } label: {
                    Text("Keep Media For").settingInfo(.mediaCacheTTL)
                }
                .disabled(configService.config.disableMediaCache)

                Button(role: .destructive) {
                    confirmClear = true
                } label: {
                    HStack {
                        Label("Clear Media Cache", systemImage: "trash")
                        Spacer()
                        if let cacheBytes {
                            Text(ByteCountFormatter.string(fromByteCount: cacheBytes, countStyle: .file))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .settingInfo(.mediaClearCache)
            } header: {
                Text("Cache")
            }
        }
        .task { await measureCache() }
        .alert("Clear Media Cache?", isPresented: $confirmClear) {
            Button("Cancel", role: .cancel) { }
            Button("Clear", role: .destructive) { clearCache() }
        } message: {
            Text(Self.clearMessage(cacheBytes))
        }
        .groupedFormStyleCompat()
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    static func clearMessage(_ bytes: Int64?) -> String {
        let size = bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) + " of " } ?? ""
        return "Removes \(size)temporary copies of images and videos. They download again when you view them. Your vault and your Blossom servers are not touched."
    }

    private func measureCache() async {
        let bytes = await Task.detached(priority: .utility) { MediaCacheService.shared.cacheSizeBytes() }.value
        cacheBytes = bytes
    }

    private func clearCache() {
        Task {
            let result = await Task.detached(priority: .userInitiated) { MediaCacheService.shared.clearCache() }.value
            let freed = ByteCountFormatter.string(fromByteCount: result.bytesFreed, countStyle: .file)
            if result.filesFailed == 0 {
                ActionToastManager.shared.show(icon: "trash.fill", message: "Cleared \(freed) of temporary copies", color: Color.havenVerified)
            } else {
                ErrorNotificationManager.shared.show("Cleared \(freed), but \(result.filesFailed) files could not be removed", icon: "exclamationmark.triangle.fill", style: .warning)
            }
            await measureCache()
        }
    }
}

/// Who may write to your relay's inbox and chat, and how fast. These used
/// to be split between "Performance & Limits" and "Global Web of Trust" in
/// Advanced, although both answer the same question.
struct RelayAccessSettingsView: View {
    @EnvironmentObject var configService: ConfigService

    var body: some View {
        Form {
            Section {
                Stepper(value: $configService.config.chatRelayWotDepth, in: 1...5) {
                    HStack {
                        Text("Follow Distance").settingInfo(.relayWotDepth)
                        Spacer()
                        Text("\(configService.config.chatRelayWotDepth)")
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                }
                Stepper(value: $configService.config.chatRelayMinFollowers, in: 0...100) {
                    HStack {
                        Text("Minimum Followers").settingInfo(.relayMinFollowers)
                        Spacer()
                        Text("\(configService.config.chatRelayMinFollowers)")
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                }
                Picker(selection: $configService.config.wotRefreshInterval) {
                    Text("Every hour").tag("1h")
                    Text("Every 12 hours").tag("12h")
                    Text("Every day").tag("24h")
                    Text("Every week").tag("168h")
                } label: {
                    Text("Refresh Trust List").settingInfo(.relayWotRefresh)
                }
            } header: {
                Text("Web of Trust")
            }

            Section {
                Stepper(value: $configService.config.outboxMaxEventsPerMinute, in: 10...1000, step: 10) {
                    HStack {
                        Text("Events").settingInfo(.relayRateLimits)
                        Spacer()
                        Text("\(configService.config.outboxMaxEventsPerMinute) / min")
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                }
                Stepper(value: $configService.config.outboxMaxConnectionsPerMinute, in: 1...100) {
                    HStack {
                        Text("Connections")
                        Spacer()
                        Text("\(configService.config.outboxMaxConnectionsPerMinute) / min")
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                }
            } header: {
                Text("Rate Limits")
            }
        }
        .groupedFormStyleCompat()
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

/// Mac only in the sidebar: two switches about when the relay comes up.
/// iPhone shows auto-start inline in the Settings list instead.
struct StartupSettingsView: View {
    @EnvironmentObject var configService: ConfigService

    var body: some View {
        Form {
            Section {
                #if os(macOS)
                Toggle("Launch at Login", isOn: $configService.config.launchAtLogin)
                #endif
                Toggle(isOn: $configService.config.autoStartRelay) {
                    Text("Start Relay Automatically").settingInfo(.relayAutoStart)
                }
            }
        }
        .groupedFormStyleCompat()
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
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
            // No "Seed Relays File" field: the app writes that file from the
            // list below on every relay start, so a typed path was ignored.
            Section {
                DatePicker(selection: importDateBinding, displayedComponents: .date) {
                    Text("Start Date").settingInfo(.relayImport)
                }
            }

            Section {
                RelayListEditor(relays: $configService.config.importSeedRelays)
            } header: {
                Text("Import From")
            }
        }
        .groupedFormStyleCompat()
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

/// The NIP-50 relays Global search asks, per device (UserDefaults, not the
/// relay config — the relay never reads this list). Lives on the Feed page:
/// it was a separate "Search Relays" row among the relay's own settings,
/// which made it look like something the relay did.
struct SearchRelaysSection: View {
    @State private var relays: [String] = SearchRelaySettings.relays
    @State private var isDefault = SearchRelaySettings.isDefault

    var body: some View {
        Section {
            RelayListEditor(relays: Binding(
                get: { relays },
                // Shown = saved: the same normalization the store applies.
                set: { relays = SearchRelayDefaults.normalized($0) }
            ), duplicateKey: SearchRelayDefaults.key)

            Button("Reset to Defaults") {
                SearchRelaySettings.resetToDefaults()
                isDefault = true
                relays = SearchRelaySettings.relays
            }
            .disabled(isDefault)
        } header: {
            Text("Search Relays").settingInfo(.feedSearchRelays)
        }
        .onChange(of: relays) { _, newValue in
            // A reset has already cleared the stored list; writing the
            // defaults back would pin them and stop future default changes.
            if isDefault && newValue == SearchRelaySettings.relays { return }
            SearchRelaySettings.relays = newValue
            isDefault = false
        }
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
                Text("Notes").settingInfo(.relayBackup)
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
                Text("Media")
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

/// Everything about what the feed shows and where it reads from. The three
/// switches are the same values as the feed's toolbar buttons, so flipping
/// one in either place flips both.
struct FeedSettingsView: View {
    @EnvironmentObject var configService: ConfigService

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $configService.config.showReposts) {
                    Text("Show Reposts").settingInfo(.feedReposts)
                }
                Toggle(isOn: $configService.config.showReplies) {
                    Text("Show Replies").settingInfo(.feedReplies)
                }
                Toggle(isOn: $configService.config.autoLoadNewPosts) {
                    Text("Auto-Load New Posts").settingInfo(.feedAutoLoad)
                }
            } header: {
                Text("What You See")
            }

            Section {
                RelayListEditor(relays: $configService.config.feedRelays)
            } header: {
                Text("Feed Relays").settingInfo(.feedRelays)
            }

            SearchRelaysSection()
        }
        .groupedFormStyleCompat()
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onChange(of: configService.config.showReposts) { _, _ in
            FeedService.shared.recomputeFilteredNotes()
        }
        .onChange(of: configService.config.showReplies) { _, _ in
            FeedService.shared.recomputeFilteredNotes()
        }
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
                Text("DM Relays").settingInfo(.shareDMRelays)
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
            // The raw "Blastr Relays File" field is gone: it named a JSON file
            // inside the relay's data folder that the app writes itself from
            // this list, so editing it only ever broke the broadcast.
            Section {
                RelayListEditor(relays: $configService.config.blastrRelays)
            } header: {
                Text("Broadcast Relays").settingInfo(.shareBroadcast)
            }
        }
        .groupedFormStyleCompat()
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
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
                Text("Wallet Connect").settingInfo(.walletNWC)
            } footer: {
                Text("Paste a nostr+walletconnect:// link.")
            }

            if !configService.config.nwcURI.isEmpty {
                Section("Zaps") {
                    HStack {
                        Text("Default Zap").settingInfo(.walletDefaultZap)
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


            // Bitcoin Taproot wallet derived from Nostr keypair (BIP-341)
            Section {
                Toggle(isOn: $configService.config.showBitcoinWallet) {
                    Label {
                        Text("Bitcoin Address").settingInfo(.walletBitcoin)
                    } icon: {
                        Image(systemName: "bitcoinsign.circle")
                    }
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
                        Text("Text Size").settingInfo(.displayTextSize)
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
                Text("Text")
            }

            // OLED black is the app's only appearance now, so there is nothing
            // left to toggle here — the section was removed along with the
            // colour-theme picker below.

            #if os(iOS)
            Section {
                Toggle(isOn: $configService.config.disableTabBarAnimation) {
                    Label {
                        Text("Keep Tab Bar Full Size").settingInfo(.displayTabBarAnimation)
                    } icon: {
                        Image(systemName: "rectangle.bottombar.fill")
                    }
                }
                .onChange(of: configService.config.disableTabBarAnimation) { _, _ in
                    configService.save()
                }
            } header: {
                Text("Tab Bar")
            }
            #endif

            Section {
                Toggle(isOn: $configService.config.zapsOnlyMode) {
                    Label {
                        Text("Zaps Only").settingInfo(.displayZapsOnly)
                    } icon: {
                        Image(systemName: "bolt.fill")
                    }
                }
                .onChange(of: configService.config.zapsOnlyMode) { _, _ in
                    configService.save()
                }
            } header: {
                Text("Engagement")
            }

            if !configService.config.zapsOnlyMode {
                Section {
                    // A tap gesture rather than a Button: the (i) is a button
                    // too, and a Button inside a Button's label never fires.
                    HStack {
                        Label("Default Reaction", systemImage: "heart.fill")
                            .foregroundColor(.primary)
                        InfoButton(.displayDefaultReaction)
                        Spacer()
                        Text(configService.config.defaultReactionEmoji)
                            .font(.appSystem(size: 24))
                        Image(systemName: "chevron.right")
                            .font(.appSystem(size: 12))
                            .foregroundColor(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { showEmojiPicker = true }
                    .accessibilityElement(children: .contain)
                    .accessibilityAddTraits(.isButton)
                } header: {
                    Text("Reactions")
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
                CommitOnEndTextField("relay.yourdomain.com", text: $configService.config.relayURL)
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
                Text("Relay Domain").settingInfo(.relayDomain)
            }

            // MARK: - Port
            Section {
                HStack {
                    Text("Port").settingInfo(.relayPort)
                    Spacer()
                    CommitOnEndTextField("3355", text: Binding(
                        get: { String(configService.config.relayPort) },
                        // A value that isn't a port is dropped; the field
                        // snaps back to the port in use.
                        set: { if let port = Int($0), (1...65535).contains(port) { configService.config.relayPort = port } }
                    ))
                        .frame(width: 80)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                }
            } header: {
                Text("Network")
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

    /// Track computed URLs from the previous save so we can migrate array entries on URL change.
    @State private var prevWssURL: String = ""
    @State private var prevHttpsURL: String = ""

    var body: some View {
        Form {
            // ── URL Input ──────────────────────────────────────────────
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    CommitOnEndTextField("https://relay.example.com", text: $configService.config.macRelayURL)
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
                }
                .padding(.vertical, 4)
            } header: {
                Text("Your Mac's Address").settingInfo(.relaySync)
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
                    Text("Also Used For")
                }

                // ── Sync ───────────────────────────────────────────────
                Section {
                    MacRelaySyncStatusView()
                } header: {
                    Text("Sync")
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
    @ObservedObject private var waitingPosts = MediaPostQueue.shared

    @State private var newMirrorURL = ""
    #if os(macOS)
    @StateObject private var fipsDetection = FIPSDetectionService()
    #else
    @State private var isVPNActive = false
    #endif
    
    var body: some View {
        Form {
            // Posts whose media is on this device but on no outside server
            // yet. They send themselves; this is where the user can see them.
            if !waitingPosts.posts.isEmpty {
                Section {
                    ForEach(waitingPosts.posts) { post in
                        HStack(spacing: 12) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.appSystem(size: 18))
                                .foregroundColor(.orange)
                                .frame(width: 24, height: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(post.body.isEmpty ? "Post with \(post.media.count) attachment(s)" : post.body)
                                    .font(.appSubheadline)
                                    .lineLimit(2)
                                Text("Waiting for a media server since \(post.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.appCaption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                waitingPosts.discard(id: post.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 4)
                    }
                    Button("Try sending now") {
                        waitingPosts.retryAll(reason: "user")
                    }
                } header: {
                    Text("Waiting to send")
                } footer: {
                    Text("The photos are saved on this device. These posts send themselves as soon as a media server below answers.")
                }
            }

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
                            Text("Add your Mac in Sync with Mac and it's used here automatically.")
                                .font(.appCaption)
                                .foregroundColor(.secondary.opacity(0.7))
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("Your Mac")
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
                Text("Other Servers").settingInfo(.shareMediaServers)
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
                    Text("Auto-Mirror Media")
                        .font(.appBody)
                        .settingInfo(.shareAutoMirror)
                }
            } header: {
                Text("Offline Copies")
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
                    Text("Publish .fips Address")
                        .font(.appBody)
                        .settingInfo(.shareFIPS)
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

/// A text field that writes to its binding only when editing ends (Return,
/// focus leaving, or the page closing). For settings the relay reads at
/// start: every write of a half-typed port or domain would otherwise be a
/// saved config, and a saved relay-facing config restarts the relay.
struct CommitOnEndTextField: View {
    @EnvironmentObject private var configService: ConfigService
    @EnvironmentObject private var relayManager: RelayProcessManager
    private let title: String
    @Binding private var text: String
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    init(_ title: String, text: Binding<String>) {
        self.title = title
        self._text = text
    }

    var body: some View {
        TextField(title, text: $draft)
            .focused($isFocused)
            .onSubmit { commit() }
            .onChange(of: isFocused) { _, focused in
                if !focused { commit() }
            }
            .onChange(of: text) { _, newValue in
                if !isFocused { draft = newValue }
            }
            .onAppear { draft = text }
            .onDisappear {
                // Leaving Settings from this page, SettingsView's own
                // onDisappear may already have saved, and its onChange
                // no longer fires. Save and apply here so the edit isn't lost.
                if commit() {
                    configService.save()
                    relayManager.applySavedConfig(configService.config)
                }
            }
    }

    /// Returns whether the binding was written.
    @discardableResult
    private func commit() -> Bool {
        let changed = draft != text
        if changed { text = draft }
        // The binding may reject or normalise the value (an out-of-range
        // port); show what was actually kept.
        draft = text
        return changed
    }
}
