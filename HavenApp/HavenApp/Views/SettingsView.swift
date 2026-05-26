import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import UniformTypeIdentifiers

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
        case importNotes = "Import"
        case backup = "Backup"
        case blastr = "Blastr"
        case blossom = "Blossom"
        case macRelay = "Mac Relay"
        case advanced = "Advanced"
        case wallet = "Wallet"
        case logs = "Logs"

        var id: String { self.rawValue }

        var icon: String {
            switch self {
            case .accounts: return "person.badge.key"
            case .blocked: return "person.crop.circle.badge.xmark"
            case .appearance: return "paintpalette"
            case .feed: return "newspaper"
            case .dm: return "bubble.left.and.bubble.right"
            case .importNotes: return "square.and.arrow.down"
            case .backup: return "externaldrive.fill"
            case .blastr: return "paperplane"
            case .blossom: return "server.rack"
            case .macRelay: return "desktopcomputer"
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
    }

    private var macOSBody: some View {
        HStack(spacing: 0) {
            settingsSidebar
            
            Divider()
                .background(Color.platformSeparator)
            
            // CONTENT VIEW DETAIL PANEL
            ZStack {
                Color(red: 0.08, green: 0.08, blue: 0.1)
                    .ignoresSafeArea()
                
                VStack(alignment: .leading, spacing: 0) {
                    // Header of active settings panel
                    HStack {
                        Text(selectedTab.rawValue)
                            .font(.title2.bold())
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
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.havenPurple)
                Text("Settings")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
            
            Divider()
                .background(Color.platformSeparator)
                .padding(.bottom, 12)
            
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    settingsSidebarSection("Profile", items: [.accounts, .blocked])
                    settingsSidebarSection("Appearance", items: [.appearance])
                    settingsSidebarSection("Relay Configuration", items: [.feed, .blastr, .blossom, .importNotes, .backup])
                    settingsSidebarSection("System", items: [.wallet, .advanced, .logs])
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
                            .font(.system(size: 11, weight: .bold))
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
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.secondary)
                    Text("Abuse Reporting: npub1vxlh...g0nvx")
                        .font(.system(size: 8, design: .monospaced))
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
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.secondary.opacity(0.7))
                .padding(.horizontal, 8)
                .padding(.bottom, 2)
            
            ForEach(items) { item in
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.1)) {
                        selectedTab = item
                    }
                }) {
                    HStack(spacing: 8) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(iconBackgroundColor(for: item))
                                .frame(width: 20, height: 20)
                            Image(systemName: item.icon)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.white)
                        }
                        
                        Text(item.rawValue)
                            .font(.system(size: 12, weight: selectedTab == item ? .semibold : .medium))
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
                tabLink(.macRelay)
            }

            Section("System") {
                tabLink(.wallet)
                tabLink(.advanced)
                tabLink(.logs)
            }
            
            Section("About") {
                VStack(spacing: 4) {
                    Text("Nostr Vault")
                        .font(.headline)
                    Text("Version \(appVersion)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Divider()
                        .padding(.vertical, 8)
                    
                    VStack(spacing: 8) {
                        Text("Support & Abuse Reporting")
                            .font(.subheadline.bold())
                        
                        Text("To report objectionable content or abusive users, contact the developer via Nostr")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        
                        Text("npub1vxlhjzeqjjhmqdy4e8sndt8kzklqlnxzew2mtt8mtakvalsckp3qa0gnvx")
                            .font(.system(size: 10, design: .monospaced))
                            .padding(8)
                            .background(Color.platformControlBackground)
                            .cornerRadius(4)
                            .onTapGesture {
                                PlatformClipboard.copy("npub1vxlhjzeqjjhmqdy4e8sndt8kzklqlnxzew2mtt8mtakvalsckp3qa0gnvx")
                            }
                        
                        Text("(Tap to copy)")
                            .font(.system(size: 8))
                            .foregroundColor(.secondary)
                            
                        Divider()
                            .padding(.vertical, 8)
                            
                        Link("Privacy Policy", destination: URL(string: "https://nostrvault.app/privacy.html")!)
                            .font(.caption)
                            .foregroundColor(.havenPurple)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .listRowBackground(Color.clear)
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Settings")
    }
    #endif

    private func tabLink(_ tab: SettingsTab) -> some View {
        NavigationLink(destination: destinationFor(tab)) {
            Label {
                Text(tab.rawValue)
                    .font(.body)
            } icon: {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(iconBackgroundColor(for: tab))
                        .frame(width: 28, height: 28)
                    Image(systemName: tab.icon)
                        .font(.system(size: 14, weight: .semibold))
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
        case .importNotes: return .orange
        case .backup: return .indigo
        case .blastr: return .cyan
        case .blossom: return .green
        case .macRelay: return .teal
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
            case .importNotes: ImportSettingsView()
            case .backup: BackupSettingsView()
            case .blastr: BlastrSettingsView()
            case .blossom: BlossomSettingsView()
            case .macRelay:
                #if os(iOS)
                MacRelaySettingsView()
                #else
                EmptyView()
                #endif
            case .advanced: AdvancedSettingsView()
            case .wallet: WalletSettingsView()
            case .logs: LogsView(logStore: relayManager.logStore)
            }
        }
        .navigationTitle(tab.rawValue)
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
                            .font(.headline)
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
                    .font(.caption.bold())
                Text("Abuse Reporting: npub1vxlh...g0nvx")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
                    .onTapGesture {
                        PlatformClipboard.copy("npub1vxlhjzeqjjhmqdy4e8sndt8kzklqlnxzew2mtt8mtakvalsckp3qa0gnvx")
                    }
                Link("Privacy Policy", destination: URL(string: "https://nostrvault.com/privacy.html")!)
                    .font(.system(size: 10))
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
                    .font(.title2)
                    .foregroundColor(.white)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Restart Required")
                        .font(.headline)
                        .foregroundColor(.white)
                    Text("Some changes require a relay restart to take effect.")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.8))
                }
                
                Spacer()
                
                if isRestarting {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
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
    
    // Add Account Sheet
    @State private var showAddAccount = false
    
    // Import Key Sheet
    @State private var importingNpub: String? = nil

    var body: some View {
        Form {
            Section {
                ForEach(configService.allAccountNpubs, id: \.self) { npub in
                    accountRow(npub: npub)
                }
                .onDelete { indexSet in
                    // allAccountNpubs prepends ownerNpub at index 0 — skip it
                    for index in indexSet {
                        guard index > 0 else { continue }
                        let npub = configService.allAccountNpubs[index]
                        configService.config.whitelistedNpubs.removeAll { $0.trimmingCharacters(in: .whitespacesAndNewlines) == npub }
                        if configService.config.activeAccountNpub == npub {
                            configService.config.activeAccountNpub = ""
                        }
                    }
                    configService.save()
                }
            } header: {
                Text("Accounts")
            } footer: {
                Text("Tap an account to make it active. Swipe left to remove a whitelisted account.")
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
    }
    
    private func accountRow(npub: String) -> some View {
        let hex = Bech32.decode(npub)?.hexString ?? ""
        let profile = nostrService.profiles[hex]
        let displayName = profile?.bestName ?? String(npub.prefix(12)) + "..."
        let isActive = (npub == configService.config.activeAccountNpub)
        let isOwner = (npub == configService.config.ownerNpub)
        let hasKey = isOwner || configService.hasCredential(forNpub: npub)
        
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
                        Text("Owner").font(.system(size: 10, weight: .bold)).padding(.horizontal, 6).padding(.vertical, 2).background(Color.havenPurple.opacity(0.2)).foregroundColor(.havenPurple).cornerRadius(4)
                    }
                    if hasKey {
                        Image(systemName: "key.fill").foregroundColor(.orange).font(.system(size: 10))
                    }
                }
                Text(npub).font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
            }
            
            Spacer()
            
            if !hasKey {
                Button("Import Key") {
                    importingNpub = npub
                }.font(.caption).buttonStyle(.bordered)
            }
            
            if isActive {
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            configService.config.activeAccountNpub = npub
            configService.save()
        }
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
                    .font(.headline)
                
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
                    .font(.system(size: 13, weight: .semibold))
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
                        .font(.caption)
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
                    .font(.headline)
                
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
                            .font(.system(size: 13, weight: .semibold))
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
                            .font(.system(size: 13, weight: .semibold))
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
                            .font(.body)

                        SecureField("Confirm Password", text: $importConfirm)
                            .textFieldStyle(.roundedBorder)
                            .textContentType(.newPassword)
                            .font(.body)
                    }
                    
                    if let error = importError {
                        Text(error)
                            .foregroundColor(.red)
                            .font(.caption)
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
            try configService.setCredential(nsec: importNsec, password: importPassword, forNpub: npub)
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

struct BlockedSettingsView: View {
    @EnvironmentObject var configService: ConfigService
    @ObservedObject private var nostrService = NostrService.shared
    
    @State private var searchInput = ""
    @State private var isSearching = false
    
    var blockedNpubs: [String] {
        configService.config.blockedNpubsPerAccount[configService.config.activeAccountNpub] ?? []
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
                                Text(npub).font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Button("Unblock") {
                                configService.unblockProfile(npub)
                            }.foregroundColor(.red)
                        }
                    }
                }
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
                Toggle("Disable Media Cache", isOn: $configService.config.disableMediaCache)
                
                Button(role: .destructive) {
                    MediaCacheService.shared.clearCache()
                } label: {
                    Label("Clear Media Cache", systemImage: "trash")
                }
            } header: {
                Text("Media Cache")
            } footer: {
                Text("Clearing the cache will remove downloaded remote images but won't touch your local Blossom data.")
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
            
            #if os(macOS)
            Section {
                Toggle("Allow Network Access", isOn: $configService.config.allowNetworkAccess)
            } header: {
                Text("Network")
            } footer: {
                Text("When enabled, the relay listens on all network interfaces (0.0.0.0) instead of localhost only. This makes your relay accessible over Tailscale, LAN, or other networks. Requires a relay restart to take effect.")
            }
            #endif
            
            Section("Diagnostics & Startup") {
                Picker("Log Level", selection: $configService.config.logLevel) {
                    Text("Debug").tag("DEBUG")
                    Text("Info").tag("INFO")
                    Text("Warning").tag("WARN")
                    Text("Error").tag("ERROR")
                }
                
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
    
    var body: some View {
        Form {
            Section {
                TextField("Start Date", text: $configService.config.importStartDate)
                TextField("Seed Relays File", text: $configService.config.importSeedRelaysFile)
            } header: {
                Text("Import Configuration")
            } footer: {
                Text("Format: YYYY-MM-DD. Notes will be fetched starting from this date.")
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

    @State private var isExportingJSONL = false
    @State private var isImportingJSONL = false
    @State private var isExportingBlossom = false
    @State private var isImportingBlossom = false
    @State private var statusMessage = ""
    @State private var showFileImporter = false
    @State private var showBlossomImporter = false
    
    var body: some View {
        Form {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Export Notes")
                            .font(.body)
                        Text("Save all notes and metadata as a JSONL backup")
                            .font(.caption)
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
                            .font(.body)
                        Text("Restore notes from a Nostr Vault JSONL backup (.zip)")
                            .font(.caption)
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
                            .font(.body)
                        Text("Save all Blossom media files as a backup")
                            .font(.caption)
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
                            .font(.body)
                        Text("Restore media from a Blossom backup (.zip)")
                            .font(.caption)
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
                            .foregroundColor(statusMessage.contains("failed") || statusMessage.contains("Error") ? .red : .green)
                        Text(statusMessage)
                            .font(.callout)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .groupedFormStyleCompat()
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.zip], allowsMultipleSelection: false) { result in
            handleJSONLImport(result)
        }
        .fileImporter(isPresented: $showBlossomImporter, allowedContentTypes: [.zip], allowsMultipleSelection: false) { result in
            handleBlossomImport(result)
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
        showBlossomImporter = true
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
                            .foregroundColor(.green)
                        Text("DM relay preferences published to network")
                            .font(.caption)
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

        // Always include local relay
        let localRelay = "wss://127.0.0.1:\(configService.config.relayPort)"
        if !relays.contains(localRelay) {
            relays.insert(localRelay, at: 0)
        }

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
                    .foregroundColor(.green)
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
                                .font(.caption)
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
                                .font(.system(size: 15, weight: .semibold))
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
    
    var body: some View {
        Form {
            Section {
                #if os(macOS)
                macOSGrid
                #else
                iOSList
                #endif
            } header: {
                Text("Accent Theme")
            } footer: {
                Text("Choose an accent color for the Nostr Vault interface. This will change the primary color and gradients across the application.")
            }
        }
        .groupedFormStyleCompat()
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
    
    #if os(macOS)
    private var macOSGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 16)], spacing: 16) {
            ForEach(AppTheme.allCases) { theme in
                ThemeCard(theme: theme, isSelected: configService.config.themeColor == theme.rawValue) {
                    configService.config.themeColor = theme.rawValue
                    configService.save()
                }
            }
        }
        .padding(.vertical, 8)
    }
    #endif
    
    private var iOSList: some View {
        ForEach(AppTheme.allCases) { theme in
            Button(action: {
                configService.config.themeColor = theme.rawValue
                configService.save()
            }) {
                HStack {
                    Circle()
                        .fill(LinearGradient(
                            colors: [theme.primaryColor, theme.lightColor],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                        .frame(width: 24, height: 24)
                        .overlay(Circle().stroke(Color.primary.opacity(0.1), lineWidth: 1))
                    
                    Text(theme.displayName)
                        .foregroundColor(.primary)
                    
                    Spacer()
                    
                    if configService.config.themeColor == theme.rawValue {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(theme.primaryColor)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }
}

#if os(macOS)
struct ThemeCard: View {
    let theme: AppTheme
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(
                            colors: [theme.primaryColor, theme.lightColor],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                        .frame(width: 48, height: 48)
                        .overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 1))
                        .shadow(color: theme.primaryColor.opacity(isSelected ? 0.4 : 0.1), radius: 6, x: 0, y: 3)
                    
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
                
                Text(theme.displayName)
                    .font(.subheadline)
                    .fontWeight(isSelected ? .bold : .regular)
                    .foregroundColor(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? Color.primary.opacity(0.05) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? theme.primaryColor : Color.gray.opacity(0.2), lineWidth: isSelected ? 2 : 1)
            )
            .scaleEffect(isHovered ? 1.02 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
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
                        .font(.caption)
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
                    // Always-on: WebSocket sync
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.body)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("WebSocket Sync")
                                .font(.subheadline.bold())
                            Text(wssURL)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.vertical, 2)

                    // Include in Import
                    let inImport = configService.config.importSeedRelays.contains(wssURL)
                    Toggle(isOn: Binding(
                        get: { inImport },
                        set: { include in syncImportRelay(wssURL: wssURL, include: include) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Include in Import")
                                .font(.body)
                            Text(wssURL)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }

                    // Include in Blastr
                    let inBlastr = configService.config.blastrRelays.contains(wssURL)
                    Toggle(isOn: Binding(
                        get: { inBlastr },
                        set: { include in syncBlastrRelay(wssURL: wssURL, include: include) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Include in Blastr")
                                .font(.body)
                            Text(wssURL)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }

                    // Include as Blossom Mirror
                    let inMirror = configService.config.blossomMirrors.contains(httpsURL)
                    Toggle(isOn: Binding(
                        get: { inMirror },
                        set: { include in syncMirror(httpsURL: httpsURL, include: include) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Include as Blossom Mirror")
                                .font(.body)
                            Text(httpsURL)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                } header: {
                    Text("Derived Addresses")
                } footer: {
                    Text("WebSocket sync runs automatically whenever the app is foregrounded. Enabling Import, Blastr, or Blossom Mirror adds your Mac relay to those lists so outbound traffic also reaches your personal relay.")
                }

                // ── Sync Controls ──────────────────────────────────────
                Section {
                    if macSyncService.isSyncing {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(macSyncService.syncStatus)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } else if !macSyncService.syncStatus.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: macSyncService.notesSynced > 0 ? "checkmark.circle.fill" : "info.circle.fill")
                                .foregroundColor(macSyncService.notesSynced > 0 ? .green : .blue)
                                .font(.caption)
                            Text(macSyncService.syncStatus)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    if let lastSync = macSyncService.lastSyncDate {
                        HStack(spacing: 6) {
                            Image(systemName: "clock")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("Last sync \(lastSync, style: .relative) ago")
                                .font(.caption2)
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
                    Text("Sync Now fetches notes missed since the last sync. Full Resync resets the timestamp and re-fetches everything from the beginning.")
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

    // MARK: - Toggle helpers

    private func syncImportRelay(wssURL: String, include: Bool) {
        if include {
            if !configService.config.importSeedRelays.contains(wssURL) {
                configService.config.importSeedRelays.append(wssURL)
            }
        } else {
            configService.config.importSeedRelays.removeAll { $0 == wssURL }
        }
        configService.save()
    }

    private func syncBlastrRelay(wssURL: String, include: Bool) {
        if include {
            if !configService.config.blastrRelays.contains(wssURL) {
                configService.config.blastrRelays.append(wssURL)
            }
        } else {
            configService.config.blastrRelays.removeAll { $0 == wssURL }
        }
        configService.save()
    }

    private func syncMirror(httpsURL: String, include: Bool) {
        if include {
            if !configService.config.blossomMirrors.contains(httpsURL) {
                configService.config.blossomMirrors.append(httpsURL)
            }
        } else {
            configService.config.blossomMirrors.removeAll { $0 == httpsURL }
        }
        configService.save()
        NostrService.shared.publishServerList()
    }

    // MARK: - URL change migration

    /// When the Mac relay URL changes, update any array entries that were derived from the old URL
    /// so Import relays, Blastr relays, and Blossom Mirrors stay in sync automatically.
    private func migrateRelayURLs() {
        let newWss = configService.config.macRelayWssURL
        let newHttps = configService.config.macRelayHttpsURL

        if !prevWssURL.isEmpty && prevWssURL != newWss {
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
    
    var body: some View {
        Form {
            // Section 1: Auto-Applied Blossom Server
            Section {
                let macHttps = configService.config.macRelayHttpsURL
                if !macHttps.isEmpty {
                    HStack(spacing: 12) {
                        Image(systemName: "desktopcomputer")
                            .font(.system(size: 18))
                            .foregroundColor(.green)
                            .frame(width: 24, height: 24)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                Text("Mac Relay Sync Server")
                                    .font(.subheadline.bold())
                                    .foregroundColor(.white)
                                
                                Text("Active")
                                    .font(.system(size: 9, weight: .bold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.green.opacity(0.15))
                                    .foregroundColor(.green)
                                    .cornerRadius(4)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 4)
                                            .stroke(Color.green.opacity(0.3), lineWidth: 1)
                                    )
                            }
                            Text(macHttps)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                } else {
                    HStack(spacing: 12) {
                        Image(systemName: "desktopcomputer.badge.warning")
                            .font(.system(size: 18))
                            .foregroundColor(.secondary)
                            .frame(width: 24, height: 24)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("No Mac Sync Relay Configured")
                                .font(.subheadline.bold())
                                .foregroundColor(.secondary)
                            Text("Configure your Mac relay in the 'Mac Relay' tab to automatically apply it here.")
                                .font(.caption)
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
                        .font(.subheadline)
                        .padding(.vertical, 4)
                } else {
                    ForEach(mirrors, id: \.self) { url in
                        HStack {
                            Image(systemName: "server.rack")
                                .font(.system(size: 14))
                                .foregroundColor(.havenPurple)
                            Text(url)
                                .font(.system(size: 12, design: .monospaced))
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
                            .foregroundColor(.green)
                            .font(.title3)
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
                            .font(.body)
                            .foregroundColor(.white)
                        Text("Download your media from external Blossom mirrors to local storage")
                            .font(.caption)
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
                            .font(.body)
                            .foregroundColor(.white)
                        Text("Automatically download your media from mirrors when the relay starts")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("Media Mirroring")
            } footer: {
                Text("Downloads your own Blossom media from active servers to your local relay for offline access.")
            }
        }
        .groupedFormStyleCompat()
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
    
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

// RelayListEditor and LogsView moved to separate files

