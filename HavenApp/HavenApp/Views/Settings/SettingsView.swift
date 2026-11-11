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
    /// The page open in the Mac sidebar.
    @State private var macGroup: MacGroup = .account
    /// A pane on that page to scroll to (a jump-bar click, or a request
    /// from elsewhere in the app for a pane by name).
    @State private var macScrollTarget: SettingsTab?
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
        case listBackups = "List backups"
        case wallet = "Wallet"
        case privacy = "Privacy"
        case feed = "Feed"
        case appearance = "Appearance"
        case media = "Media & Cache"
        case pushNotifications = "Notifications"
        case relays = "Relays"
        case blossom = "Media Servers"
        case macRelay = "Desktop vault sync"
        case relayAccess = "Who Can Reach You"
        case fipsMesh = "Mesh"
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
            case .listBackups: return "clock.arrow.circlepath"
            case .wallet: return "bitcoinsign.circle"
            case .privacy: return "hand.raised"
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
    /// process owns the value: the iPhone list and the iPad column. The Mac
    /// sidebar has six pages instead (`MacGroup`).
    ///
    /// Startup is a pane on the Mac (auto-start plus launch at login) but a
    /// single inline switch on iPhone, where a page for one toggle is a
    /// dead end.
    static var groups: [(title: String, tabs: [SettingsTab])] {
        #if os(macOS)
        let relayTabs: [SettingsTab] = [.macRelay, .relayAccess, .importNotes, .backup, .startup]
        #else
        let relayTabs: [SettingsTab] = [.macRelay, .relayAccess, .importNotes, .backup]
        #endif
        return [
            ("Account", [.accounts, .blocked, .recentlyDeleted, .followingBackup, .listBackups, .wallet, .privacy]),
            ("Feed & Display", [.feed, .appearance, .media]),
            ("Notifications", [.pushNotifications]),
            ("Relays", [.relays, .blossom]),
            ("Your Vault", relayTabs),
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
            select(.relays)
        }
        .onReceive(NotificationCenter.default.publisher(for: .havenOpenFipsMeshSettings)) { _ in
            select(.fipsMesh)
        }
        .onReceive(NotificationCenter.default.publisher(for: .havenOpenMediaServerSettings)) { _ in
            select(.blossom)
        }
        #endif
    }

    private func takePaneRequest() {
        guard let pane = paneRequest.wrappedValue else { return }
        select(pane)
        paneRequest.wrappedValue = nil
    }

    #if os(macOS)
    /// The Mac's Settings: six pages, one per job, in place of a column of
    /// two dozen. Each page stacks the panes it holds, so everything that
    /// used to be one click away still is, and a whole job (say, keeping
    /// the vault reachable) reads top to bottom on one page.
    ///
    /// Your Vault opens with Startup: for a relay that runs all day, Launch
    /// at Login and Start Vault Automatically are the switches that matter
    /// most. iPhone and iPad keep `groups`, where a pane is its own page.
    enum MacGroup: String, CaseIterable, Identifiable {
        case account = "Account"
        case vault = "Your Vault"
        case relaysMedia = "Relays & Media"
        case backups = "Backups"
        case reading = "Reading"
        case help = "Help"

        var id: String { rawValue }

        var tabs: [SettingsTab] {
            switch self {
            case .account: return [.accounts, .wallet, .bitcoin, .privacy, .blocked]
            case .vault: return [.startup, .macRelay, .relayAccess, .fipsMesh, .advanced]
            case .relaysMedia: return [.relays, .blossom, .media]
            case .backups: return [.backup, .followingBackup, .listBackups, .recentlyDeleted, .importNotes]
            case .reading: return [.feed, .appearance, .pushNotifications, .proofOfWork]
            case .help: return [.tutorials, .logs]
            }
        }

        var icon: String {
            switch self {
            case .account: return "person.crop.circle"
            case .vault: return "lock.shield"
            case .relaysMedia: return "point.3.connected.trianglepath.dotted"
            case .backups: return "clock.arrow.circlepath"
            case .reading: return "text.book.closed"
            case .help: return "questionmark.circle"
            }
        }

        @MainActor
        var color: Color {
            switch self {
            case .account: return .blue
            case .vault: return .green
            case .relaysMedia: return .havenPurple
            case .backups: return .indigo
            case .reading: return .pink
            case .help: return .gray
            }
        }

        /// What the page holds, under its name in the sidebar. Help also
        /// carries About, which is not a pane of its own.
        var summary: String {
            let names = tabs.map(\.title) + (self == .help ? ["About"] : [])
            return names.joined(separator: ", ")
        }

        static func containing(_ tab: SettingsTab) -> MacGroup {
            allCases.first { $0.tabs.contains(tab) } ?? .account
        }
    }

    /// Where About sits on the Help page; not a `SettingsTab`.
    private static let aboutAnchor = "settings.about"

    private var macOSBody: some View {
        HStack(spacing: 0) {
            macSidebar

            ZStack {
                Color.platformWindowBackground
                    .ignoresSafeArea()

                VStack(alignment: .leading, spacing: 0) {
                    macPageHeader

                    Divider()
                        .background(Color.platformSeparator)

                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(macGroup.tabs.enumerated()), id: \.element) { index, tab in
                                    if index > 0 {
                                        Divider()
                                            .background(Color.platformSeparator)
                                            .padding(.vertical, 28)
                                    }
                                    macPaneSection(tab)
                                        .id(tab)
                                }
                                if macGroup == .help {
                                    Divider()
                                        .background(Color.platformSeparator)
                                        .padding(.vertical, 28)
                                    macAboutSection
                                        .id(Self.aboutAnchor)
                                }
                            }
                            .padding(24)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        // A new page starts at its top, not at the old page's offset.
                        .id(macGroup)
                        .task(id: macScrollTarget) {
                            guard let target = macScrollTarget else { return }
                            // The page has to lay out before it can scroll to a pane on it.
                            try? await Task.sleep(nanoseconds: 60_000_000)
                            withAnimation(Motion.control) { proxy.scrollTo(target, anchor: .top) }
                            macScrollTarget = nil
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: isEmbedded ? .infinity : 900, maxHeight: isEmbedded ? .infinity : 650)
    }

    /// The page name, and a jump bar to each pane on it. The bar floats over
    /// the page as chrome, so it is the one glass surface here; the panes
    /// themselves stay on the plain dark page.
    private var macPageHeader: some View {
        HStack(alignment: .center, spacing: 16) {
            Text(macGroup.rawValue)
                .font(.appTitle2.bold())
                .foregroundColor(.white)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if macGroup.tabs.count > 1 {
                ViewThatFits(in: .horizontal) {
                    macJumpBar(showsTitles: true)
                    macJumpBar(showsTitles: false)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private func macJumpBar(showsTitles: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(macGroup.tabs) { tab in
                Button {
                    macScrollTarget = tab
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: tab.icon)
                            .font(.appSystem(size: 11, weight: .semibold))
                        if showsTitles {
                            Text(tab.title)
                                .font(.appSystem(size: 11, weight: .medium))
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                    .foregroundColor(.white.opacity(0.85))
                    .padding(.horizontal, showsTitles ? 10 : 8)
                    .padding(.vertical, 5)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Go to \(tab.title)")
                .accessibilityLabel("Go to \(tab.title)")
            }
        }
        .padding(3)
        .applyGlassCapsule()
    }

    /// One pane on a page: its name, then the pane exactly as it was.
    private func macPaneSection(_ tab: SettingsTab) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(iconBackgroundColor(for: tab))
                        .frame(width: 22, height: 22)
                    Image(systemName: tab.icon)
                        .font(.appSystem(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                }
                Text(tab.title)
                    .font(.appSystem(size: 15, weight: .bold))
                    .foregroundColor(.white)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            destinationFor(tab)
                .environmentObject(configService)
                .environmentObject(relayManager)
        }
    }

    /// Version and abuse reporting, which used to be squeezed into the
    /// sidebar's footer at 8pt.
    private var macAboutSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.gray)
                        .frame(width: 22, height: 22)
                    Image(systemName: "info.circle")
                        .font(.appSystem(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                }
                Text("About")
                    .font(.appSystem(size: 15, weight: .bold))
                    .foregroundColor(.white)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: 10) {
                Text("Nostr Vault \(appVersion)")
                    .font(.appHeadline)
                    .foregroundColor(.white)

                Text("To report objectionable content or abusive users, contact the developer on Nostr:")
                    .font(.appCaption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Text(Self.abuseReportingNpub)
                        .font(.appSystem(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Copy") { PlatformClipboard.copy(Self.abuseReportingNpub) }
                        .controlSize(.small)
                }

                Link("Privacy Policy", destination: URL(string: "https://nostrvault.app/privacy.html")!)
                    .font(.appCaption)
                    .foregroundColor(.havenPurple)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.platformControlBackground.opacity(0.5))
            .cornerRadius(10)
        }
    }

    private var macSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header suppressed when embedded: the host window's own sidebar
            // already has a "Settings" row selected right beside this one.
            if !isEmbedded {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape.fill")
                        .font(.appSystem(size: 15, weight: .bold))
                        .foregroundColor(.havenPurple)
                    Text("Settings")
                        .font(.appSystem(size: 15, weight: .bold))
                        .foregroundColor(.white)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.top, 16)
                .padding(.bottom, 10)
            } else {
                Color.clear.frame(height: 10)
            }

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
                            Text("Click to finish setup")
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
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }

            VStack(alignment: .leading, spacing: 2) {
                ForEach(MacGroup.allCases) { group in
                    macSidebarRow(group)
                }
            }
            .padding(.horizontal, 8)

            Spacer(minLength: 12)

            if relayManager.isApplyingConfig {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Restarting relay…")
                        .font(.appSystem(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .padding(12)
                .accessibilityElement(children: .combine)
            }
        }
        .frame(width: 224)
        .frame(maxHeight: .infinity, alignment: .top)
        // A floating glass sidebar, inset from the window edge (plain
        // material before macOS 26), so it reads as chrome over the page.
        .applyGlassRect(cornerRadius: 14)
        .padding(8)
    }

    private func macSidebarRow(_ group: MacGroup) -> some View {
        let isSelected = macGroup == group
        return Button {
            selectGroup(group)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(group.color)
                        .frame(width: 26, height: 26)
                    Image(systemName: group.icon)
                        .font(.appSystem(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.rawValue)
                        .font(.appSystem(size: 13, weight: isSelected ? .semibold : .medium))
                        .foregroundColor(isSelected ? .white : .white.opacity(0.85))
                    Text(group.summary)
                        .font(.appSystem(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.havenPurple.opacity(0.18) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.havenPurple.opacity(0.35) : Color.clear, lineWidth: 1)
            )
            // A clear fill does not hit-test; this makes the whole row clickable.
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(group.rawValue)
        .accessibilityHint(group.summary)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Opens a page. Leaving the page that holds Media Servers with unsaved
    /// changes asks Save / Discard first.
    private func selectGroup(_ group: MacGroup, scrollTo tab: SettingsTab? = nil) {
        let go = {
            withAnimation(Motion.control) { macGroup = group }
            if let tab, tab != group.tabs.first { macScrollTarget = tab }
        }
        if group == macGroup {
            if let tab { macScrollTarget = tab }
            return
        }
        if macGroup.tabs.contains(.blossom) { MediaServersLeaveGuard.shared.requestLeave(go) } else { go() }
    }
    #endif

    static let abuseReportingNpub = "npub1vxlhjzeqjjhmqdy4e8sndt8kzklqlnxzew2mtt8mtakvalsckp3qa0gnvx"

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
                    if group.title == "Your Vault" {
                        // One switch, so it lives here rather than behind a
                        // page of its own (the Mac has a Startup page).
                        Toggle(isOn: $configService.config.autoStartRelay) {
                            Label {
                                Text("Start Vault Automatically")
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
                select(tab)
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
            NavigationLink(destination: destinationFor(tab, pushed: true)) { tabLabel(tab) }
        }
        #else
        NavigationLink(destination: destinationFor(tab, pushed: true)) { tabLabel(tab) }
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
        case .listBackups: return .indigo
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
        case .privacy: return .blue
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
    
    /// Switches the page beside the sidebar. On the Mac that opens the page
    /// holding the pane and scrolls to it. Leaving Media Servers with
    /// unsaved changes asks Save / Discard first.
    private func select(_ tab: SettingsTab, animated: Bool = false) {
        #if os(macOS)
        selectGroup(MacGroup.containing(tab), scrollTo: tab)
        #else
        guard tab != selectedTab else { return }
        let go = {
            if animated {
                withAnimation(Motion.control) { selectedTab = tab }
            } else {
                selectedTab = tab
            }
        }
        if selectedTab == .blossom { MediaServersLeaveGuard.shared.requestLeave(go) } else { go() }
        #endif
    }

    /// `pushed`: on a navigation stack (iPhone) rather than beside the sidebar.
    @ViewBuilder
    private func destinationFor(_ tab: SettingsTab, pushed: Bool = false) -> some View {
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
            case .listBackups: ListBackupView()
            case .blossom: BlossomSettingsView(pushed: pushed)
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
            case .privacy: PrivacySettingsView()
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
