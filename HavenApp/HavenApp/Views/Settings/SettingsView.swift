import SwiftUI

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
    #if os(iOS)
    /// Width of the Settings pane. iPad Split View and the iPad sidebar layout
    /// both hand this screen less than a whole window, and under about 700pt
    /// two columns leave neither one usable, so it falls back to the phone's
    /// single list.
    @State private var paneWidth: CGFloat = 0

    /// iPad, with room for a list and a page side by side.
    private var usesTwoPane: Bool { AdaptiveLayout.usesWidth && paneWidth >= 700 }
    #endif
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif
    @Environment(\.dismiss) private var dismiss
    var isEmbedded: Bool = false
    /// A pane someone asked to open (the Mac feed's status dot asks for
    /// Relays). Passed in, not sent as a notification: Settings is not on
    /// screen to hear one until the Settings tab is open.
    var paneRequest: Binding<SettingsTab?> = .constant(nil)
    
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
        case recentlyDeleted = "Recently Deleted"
        case followingBackup = "Following Backup"
        case wallet = "Wallet"
        case feed = "Feed"
        case appearance = "Appearance"
        case media = "Media & Cache"
        case pushNotifications = "Notifications"
        case relays = "Relays"
        case blossom = "Media Servers"
        case macRelay = "Sync with Vault on Mac"
        case relayAccess = "Who Can Reach You"
        case fipsMesh = "FIPS Mesh"
        case importNotes = "Import Notes"
        case backup = "Backup & Restore"
        case startup = "Startup"
        case proofOfWork = "Proof of Work"
        case advanced = "Database & Reset"
        case bitcoin = "Bitcoin On-Chain"
        case logs = "Logs"
        case tutorials = "Tutorials"

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
            case .recentlyDeleted: return "trash"
            case .followingBackup: return "person.crop.circle.badge.clock"
            case .wallet: return "bitcoinsign.circle"
            case .feed: return "newspaper"
            case .appearance: return "paintpalette"
            case .media: return "photo.on.rectangle"
            case .pushNotifications: return "bell.badge"
            case .relays: return "point.3.connected.trianglepath.dotted"
            case .blossom: return "server.rack"
            case .macRelay:
                #if os(macOS)
                return "globe"
                #else
                return "desktopcomputer"
                #endif
            case .relayAccess: return "person.2.badge.gearshape"
            case .fipsMesh: return "point.3.filled.connected.trianglepath.dotted"
            case .importNotes: return "square.and.arrow.down"
            case .backup: return "externaldrive.fill"
            case .startup: return "power"
            case .proofOfWork: return "hammer.fill"
            case .advanced: return "gearshape.2"
            case .bitcoin: return "bitcoinsign.circle"
            case .logs: return "list.bullet.rectangle"
            case .tutorials: return "graduationcap"
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
            ("Account", [.accounts, .blocked, .recentlyDeleted, .followingBackup, .wallet]),
            ("Feed & Display", [.feed, .appearance, .media]),
            ("Notifications", [.pushNotifications]),
            ("Relays", [.relays, .blossom]),
            ("Your Vault Relay", relayTabs),
            ("Mesh", [.fipsMesh]),
            ("Help", [.tutorials]),
            ("Advanced", [.proofOfWork, .advanced, .bitcoin, .logs]),
        ]
    }

    var body: some View {
        Group {
            #if os(iOS)
            if usesTwoPane {
                padBody
            } else {
                iOSBody
            }
            #else
            macOSBody
            #endif
        }
        #if os(iOS)
        .measureWidth { paneWidth = $0 }
        #endif
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
        .onAppear(perform: takePaneRequest)
        .onChange(of: paneRequest.wrappedValue) { _, _ in takePaneRequest() }
        #if os(macOS)
        // Already on screen (including the separate Settings window, which
        // gets no paneRequest): switch here too.
        .onReceive(NotificationCenter.default.publisher(for: .havenOpenFeedRelaySettings)) { _ in
            selectedTab = .relays
        }
        .onReceive(NotificationCenter.default.publisher(for: .havenOpenFipsMeshSettings)) { _ in
            selectedTab = .fipsMesh
        }
        #endif
    }

    private func takePaneRequest() {
        guard let pane = paneRequest.wrappedValue else { return }
        selectedTab = pane
        paneRequest.wrappedValue = nil
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
                    // A clear fill does not hit-test; this makes the whole row clickable.
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 8)
    }
    
    #if os(iOS)
    /// iPad: the Mac's two-pane shape, with the iPhone's own list as the left
    /// column. Reusing the list rather than the Mac sidebar keeps every row,
    /// every word and the inline switches the Mac has no page for (Start Relay
    /// Automatically, the relay status card, Setup Incomplete) exactly as the
    /// phone has them. A tap selects the page beside the list instead of
    /// pushing it over the top of it.
    private var padBody: some View {
        HStack(spacing: 0) {
            iOSBody
                .frame(width: 340)

            Divider()
                .background(Color.platformSeparator)

            // No stack of its own: both hosts (the sidebar's Settings row and
            // the Profile gear sheet) already wrap SettingsView in a
            // NavigationStack, and SwiftUI does not support a stack nested in
            // a stack -- pushes from here (Relays -> a relay, Logs -> a file)
            // would land in the outer stack or do nothing. The page pushes
            // through that outer stack instead.
            destinationFor(selectedTab)
                .id(selectedTab)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.platformWindowBackground)
    }

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

    @ViewBuilder
    private func tabLink(_ tab: SettingsTab) -> some View {
        #if os(iOS)
        if usesTwoPane {
            Button {
                selectedTab = tab
            } label: {
                HStack(spacing: 0) {
                    tabLabel(tab)
                    Spacer(minLength: 8)
                }
                // A label alone does not hit-test its empty trailing half.
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(selectedTab == tab ? Color.havenPurple.opacity(0.18) : nil)
        } else {
            NavigationLink(destination: destinationFor(tab)) { tabLabel(tab) }
        }
        #else
        NavigationLink(destination: destinationFor(tab)) { tabLabel(tab) }
        #endif
    }

    private func tabLabel(_ tab: SettingsTab) -> some View {
        Label {
            Text(tab.title)
                .font(.appBody)
        } icon: {
            settingsIcon(tab.icon, color: iconBackgroundColor(for: tab))
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
        case .recentlyDeleted: return .gray
        case .appearance: return .purple
        case .feed: return .pink
        case .media: return .indigo
        case .relays: return .havenPurple
        case .pushNotifications: return .red
        case .importNotes: return .orange
        case .relayAccess: return .blue
        case .fipsMesh: return .teal
        case .backup: return .indigo
        case .startup: return .green
        case .followingBackup: return .teal
        // Stays system green: this list is a categorical palette for the
        // section icons (pink, mint, blue, indigo, teal…), not a status. Using
        // `havenOnline` here would give one settings row the vocabulary of a
        // health indicator.
        case .blossom: return .green
        case .macRelay: return .teal
        case .proofOfWork: return .purple
        case .advanced: return .gray
        case .bitcoin: return .orange
        case .wallet: return .orange
        case .logs: return .secondary
        case .tutorials: return .purple
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
            case .recentlyDeleted: RecentlyDeletedSettingsView()
            case .appearance: AppearanceSettingsView()
            case .feed: FeedSettingsView()
            case .relays: RelayMatrixView()
            case .pushNotifications: PushNotificationSettingsView()
            case .importNotes: ImportSettingsView()
            case .media: MediaSettingsView()
            case .relayAccess: RelayAccessSettingsView()
            case .fipsMesh:
                #if os(iOS)
                FipsMeshSettingsView()
                #else
                MacFipsMeshSettingsView()
                #endif
            case .startup: StartupSettingsView()
            case .backup: BackupSettingsView()
            case .followingBackup: FollowingBackupSettingsView()
            case .blossom: BlossomSettingsView()
            case .macRelay:
                #if os(iOS)
                MacRelaySettingsView()
                #else
                MacRelayDomainSettingsView()
                #endif
            case .proofOfWork: ProofOfWorkSettingsView()
            case .advanced: AdvancedSettingsView()
            case .bitcoin: BitcoinWalletSettingsView()
            case .wallet: WalletSettingsView()
            case .logs: LogsView(logStore: relayManager.logStore)
            case .tutorials:
                // Close Settings (a sheet on iPhone) and go to the page the
                // tutorial points at; its card waits there.
                TutorialsSettingsView { _ in
                    dismiss()
                    NotificationCenter.default.post(name: .havenOpenFeed, object: nil)
                }
            }
        }
        .navigationTitle(tab.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
    
}
