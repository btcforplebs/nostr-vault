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
    @State private var selectedTab: SettingsTab = .identity
    @State private var saveTask: Task<Void, Never>?
    @State private var isRestarting = false
    
    var needsRestart: Bool {
        guard let lastLaunch = relayManager.lastConfig else { return false }
        return configService.config != lastLaunch
    }
    
    enum SettingsTab: String, CaseIterable, Identifiable {
        case identity = "Identity"
        case accessControl = "Access Control"
        case relays = "Relays"
        case importNotes = "Import"
        case blastr = "Blastr"
        case advanced = "Advanced"
        case backup = "Backup"
        case logs = "Logs"
        
        var id: String { self.rawValue }
        
        var icon: String {
            switch self {
            case .identity: return "person.badge.key"
            case .accessControl: return "shield.lefthalf.filled"
            case .relays: return "server.rack"
            case .importNotes: return "square.and.arrow.down"
            case .blastr: return "paperplane"
            case .advanced: return "gearshape.2"
            case .backup: return "icloud"
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
        .onChange(of: configService.config) { newValue in
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
        VStack(spacing: 0) {
            TabView(selection: $selectedTab) {
                ForEach(SettingsTab.allCases) { tab in
                    destinationFor(tab)
                        .tabItem { Label(tab.rawValue, systemImage: tab.icon) }
                        .tag(tab)
                }
            }
            .environmentObject(configService)
            .environmentObject(relayManager)
            
            footer
        }
        .frame(width: 600, height: 500)
    }
    
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
                tabLink(.identity)
                tabLink(.accessControl)
            }
            
            Section("Relay Configuration") {
                tabLink(.relays)
                tabLink(.blastr)
                tabLink(.importNotes)
            }
            
            Section("System") {
                tabLink(.backup)
                tabLink(.advanced)
                tabLink(.logs)
            }
            
            Section {
                VStack(spacing: 4) {
                    Text("Haven Relay")
                        .font(.headline)
                    Text("Version 2.3.0")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .listRowBackground(Color.clear)
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Settings")
    }
    
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
        case .identity: return .blue
        case .accessControl: return .green
        case .relays: return .purple
        case .importNotes: return .orange
        case .blastr: return .cyan
        case .advanced: return .gray
        case .backup: return .indigo
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
            case .identity: IdentitySettingsView()
            case .accessControl: AccessControlSettingsView()
            case .relays: RelaySettingsView()
            case .importNotes: ImportSettingsView()
            case .blastr: BlastrSettingsView()
            case .advanced: AdvancedSettingsView()
            case .backup: BackupSettingsView()
            case .logs: LogsView()
            }
        }
        .navigationTitle(tab.rawValue)
        .navigationBarTitleDisplayMode(.inline)
    }
    
    private var footer: some View {
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

struct IdentitySettingsView: View {
    @EnvironmentObject var configService: ConfigService
    @State private var showUpdateKey = false
    @State private var newNsec = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var updateError: String?
    @State private var updateSuccess = false

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Owner npub")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    TextEditor(text: $configService.config.ownerNpub)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 100)
                        .padding(8)
                        .background(Color(.secondarySystemGroupedBackground))
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                        )
                    
                    Text("Your Nostr public key in npub format. This key has administrative access to the relay.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            } header: {
                Text("Owner Identity")
            }

            Section {
                VStack(alignment: .leading, spacing: 12) {
                    if !configService.config.ownerNcryptsec.isEmpty {
                        HStack {
                            Image(systemName: "lock.fill")
                                .foregroundColor(.green)
                            Text("Private Key (Encrypted)")
                                .font(.subheadline.bold())
                            Spacer()
                            Button(role: .destructive) {
                                configService.config.ownerNcryptsec = ""
                                configService.config.ownerNsec = ""
                                configService.save()
                            } label: {
                                Text("Clear")
                                    .font(.caption)
                            }
                        }
                        .padding(8)
                        .background(Color(.secondarySystemGroupedBackground))
                        .cornerRadius(8)

                        Text("Your private key is encrypted with NIP-49. You'll be prompted for your password when signing notes.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else if !configService.config.ownerNsec.isEmpty {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text("Private Key (Plaintext)")
                                .font(.subheadline.bold())
                            Spacer()
                            Button(role: .destructive) {
                                configService.config.ownerNsec = ""
                                configService.save()
                            } label: {
                                Text("Clear")
                                    .font(.caption)
                            }
                        }
                        .padding(8)
                        .background(Color(.secondarySystemGroupedBackground))
                        .cornerRadius(8)

                        Text("This key is stored in plaintext for backward compatibility. For security, re-enter it during setup to encrypt with NIP-49.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Image(systemName: "key.slash")
                                    .foregroundColor(.red)
                                Text("No private key configured")
                                    .font(.subheadline.bold())
                            }

                            Text("Import your nsec (private key) to compose and sign notes")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            Button(action: { showUpdateKey = true }) {
                                HStack {
                                    Image(systemName: "plus.circle.fill")
                                    Text("Import Private Key")
                                }
                                .font(.subheadline.bold())
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(Color.havenPurple)
                                .cornerRadius(8)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(8)
                        .background(Color.red.opacity(0.05))
                        .cornerRadius(8)
                        .border(Color.red.opacity(0.2), width: 1)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Private Key")
            }

            #if os(macOS)
            Section {
                TextField("relay.example.com", text: $configService.config.relayURL)

                HStack {
                    Text("Port")
                    Spacer()
                    TextField("8080", value: $configService.config.relayPort, formatter: NumberFormatter.noSeparator)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                }
            } header: {
                Text("Connection")
            } footer: {
                Text("The hostname and port where your relay will be accessible.")
            }
            #endif
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(isPresented: $showUpdateKey) {
            updateKeySheet
        }
    }

    private var updateKeySheet: some View {
        NavigationView {
            Form {
                Section("Enter Private Key") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("nsec (Nostr Secret Key)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextEditor(text: $newNsec)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 80)
                            .padding(4)
                            .background(Color(.secondarySystemGroupedBackground))
                            .cornerRadius(6)
                    }
                }

                Section("Set Password (NIP-49 Encryption)") {
                    SecureField("Password", text: $newPassword)
                    SecureField("Confirm Password", text: $confirmPassword)

                    HStack(spacing: 4) {
                        Image(systemName: "lock.fill")
                            .font(.caption)
                            .foregroundColor(.green)
                        Text("Password will be securely stored in your Keychain")
                            .font(.caption)
                            .foregroundColor(.green)
                    }

                    Text("Haven uses your password to automatically decrypt your key when signing notes. You won't need to enter it each time.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if let error = updateError {
                    Section {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }

                if updateSuccess {
                    Section {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("Password saved to Keychain — Haven will use it automatically when signing notes")
                                .font(.caption)
                        }
                    }
                }
            }
            .navigationTitle(configService.config.ownerNcryptsec.isEmpty && configService.config.ownerNsec.isEmpty ? "Import Private Key" : "Update Private Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        resetForm()
                        showUpdateKey = false
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(configService.config.ownerNcryptsec.isEmpty && configService.config.ownerNsec.isEmpty ? "Import" : "Update") {
                        savePrivateKey()
                    }
                    .disabled(newNsec.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || newPassword.isEmpty)
                }
            }
        }
    }

    private func savePrivateKey() {
        let nsecTrimmed = newNsec.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !nsecTrimmed.isEmpty else {
            updateError = "Private key cannot be empty"
            return
        }

        guard newPassword == confirmPassword else {
            updateError = "Passwords do not match"
            return
        }

        guard newPassword.count >= 8 else {
            updateError = "Password must be at least 8 characters"
            return
        }

        do {
            try configService.config.setEncryptedNsec(nsec: nsecTrimmed, password: newPassword)
            configService.save()
            updateSuccess = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                resetForm()
                showUpdateKey = false
            }
        } catch {
            updateError = "Failed to encrypt key: \(error.localizedDescription)"
        }
    }

    private func resetForm() {
        newNsec = ""
        newPassword = ""
        confirmPassword = ""
        updateError = nil
        updateSuccess = false
    }
}

struct AccessControlSettingsView: View {
    @EnvironmentObject var configService: ConfigService
    @State private var selectedList: ListType = .whitelist

    enum ListType: String, CaseIterable {
        case whitelist = "Whitelist"
        case blacklist = "Blacklist"
    }

    var body: some View {
        #if os(iOS)
        iOSBody
        #else
        macOSBody
        #endif
    }

    #if os(macOS)
    private var macOSBody: some View {
        HStack(spacing: 0) {
            List(ListType.allCases, id: \.self, selection: $selectedList) { listType in
                Label(listType.rawValue, systemImage: listType == .whitelist ? "checkmark.shield" : "xmark.shield")
            }
            .frame(width: 140)
            .listStyle(.sidebar)

            Divider()

            content(for: selectedList)
                .padding()
        }
    }
    #endif

    private var iOSBody: some View {
        Form {
            Section {
                Picker("List Type", selection: $selectedList) {
                    ForEach(ListType.allCases, id: \.self) { listType in
                        Text(listType.rawValue).tag(listType)
                    }
                }
                .pickerStyle(.segmented)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())

            content(for: selectedList)
        }
    }

    @ViewBuilder
    private func content(for type: ListType) -> some View {
        switch type {
        case .whitelist:
            Section {
                NpubListEditor(npubs: $configService.config.whitelistedNpubs)
            } header: {
                Text("Whitelisted Npubs")
            } footer: {
                Text("Additional npubs that can write to your private relay. Your owner npub is always included.")
            }

        case .blacklist:
            Section {
                NpubListEditor(npubs: $configService.config.blacklistedNpubs)
            } header: {
                Text("Blacklisted Npubs")
            } footer: {
                Text("Npubs that are explicitly blocked from your Chat and Inbox relays.")
            }
        }
    }
}

struct NpubListEditor: View {
    @Binding var npubs: [String]
    @State private var newNpub: String = ""

    var body: some View {
        Group {
            #if os(iOS)
            iOSContent
            #else
            macOSContent
            #endif
        }
    }

    private var iOSContent: some View {
        Group {
            ForEach(npubs.indices, id: \.self) { index in
                HStack {
                    Text(npubs[index])
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button(role: .destructive) {
                        npubs.remove(at: index)
                    } label: {
                        Image(systemName: "trash")
                            .foregroundColor(.red)
                    }
                }
            }
            
            HStack {
                TextField("Add npub1...", text: $newNpub)
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                
                Button(action: addNpub) {
                    Image(systemName: "plus.circle.fill")
                        .foregroundColor(.havenPurple)
                        .font(.title3)
                }
                .disabled(newNpub.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private var macOSContent: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("npub1...", text: $newNpub)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addNpub() }

                Button(action: addNpub) {
                    Image(systemName: "plus.circle.fill")
                }
                .disabled(newNpub.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            List {
                ForEach(npubs, id: \.self) { npub in
                    HStack {
                        Text(npub)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button {
                            npubs.removeAll { $0 == npub }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func addNpub() {
        let trimmed = newNpub.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !npubs.contains(trimmed) else { return }
        npubs.append(trimmed)
        newNpub = ""
    }
}

struct RelaySettingsView: View {
    @EnvironmentObject var configService: ConfigService
    @State private var selectedRelay: RelayType = .outbox
    
    enum RelayType: String, CaseIterable {
        case outbox = "Outbox"
        case inbox = "Inbox"
        case privateRelay = "Private"
        case chat = "Chat"
    }
    
    var body: some View {
        #if os(iOS)
        iOSBody
        #else
        macOSBody
        #endif
    }

    private var iOSBody: some View {
        Form {
            Section {
                Picker("Relay Type", selection: $selectedRelay) {
                    ForEach(RelayType.allCases, id: \.self) { relay in
                        Text(relay.rawValue).tag(relay)
                    }
                }
                .pickerStyle(.segmented)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())

            detailContent
        }
    }

    #if os(macOS)
    private var macOSBody: some View {
        HStack(spacing: 0) {
            // Sidebar
            List(RelayType.allCases, id: \.self, selection: $selectedRelay) { relay in
                Label(relay.rawValue, systemImage: iconFor(relay))
            }
            .frame(width: 140)
            .listStyle(.sidebar)
            
            Divider()
            
            // Detail
            if #available(macOS 13.0, *) {
                Form {
                    detailContent
                }
                .formStyle(.grouped)
                .padding()
            } else {
                Form {
                    detailContent
                }
                .padding()
            }
        }
    }
    #endif

    @ViewBuilder
    private var detailContent: some View {
        switch selectedRelay {
        case .outbox:
            RelayConfigForm(
                name: $configService.config.outboxRelayName,
                description: $configService.config.outboxRelayDescription,
                icon: $configService.config.outboxRelayIcon
            )
        case .inbox:
            RelayConfigForm(
                name: $configService.config.inboxRelayName,
                description: $configService.config.inboxRelayDescription,
                icon: $configService.config.inboxRelayIcon
            )
        case .privateRelay:
            RelayConfigForm(
                name: $configService.config.privateRelayName,
                description: $configService.config.privateRelayDescription,
                icon: $configService.config.privateRelayIcon
            )
        case .chat:
            RelayConfigForm(
                name: $configService.config.chatRelayName,
                description: $configService.config.chatRelayDescription,
                icon: $configService.config.chatRelayIcon
            )
            
            Section("Web of Trust") {
                Text("Web of Trust settings have moved to the Advanced tab.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
    
    func iconFor(_ relay: RelayType) -> String {
        switch relay {
        case .outbox: return "arrow.up.doc"
        case .inbox: return "arrow.down.doc"
        case .privateRelay: return "lock.fill"
        case .chat: return "bubble.left.and.bubble.right"
        }
    }
}

struct RelayConfigForm: View {
    @Binding var name: String
    @Binding var description: String
    @Binding var icon: String
    
    var body: some View {
        Section("Relay Info") {
            TextField("Name", text: $name)
            TextField("Description", text: $description)
            TextField("Icon URL", text: $icon)
        }
    }
}

struct AdvancedSettingsView: View {
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var relayManager: RelayProcessManager
    @State private var showResetConfirmation = false
    #if os(iOS)
    #endif
    
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
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
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
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}


struct BackupSettingsView: View {
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var relayManager: RelayProcessManager
    @State private var isExporting = false
    @State private var isImportingBackup = false
    @State private var isBackingUpBlossom = false
    @State private var backupStatusMessage = ""

    var body: some View {
        Form {
            Section {
                Picker("Provider", selection: $configService.config.backupProvider) {
                    Text("None").tag("none")
                    Text("S3 Compatible").tag("s3")
                }
                
                if configService.config.backupProvider == "s3" {
                    Stepper("Backup interval: \(configService.config.backupIntervalHours)h",
                           value: $configService.config.backupIntervalHours, in: 1...168)
                    
                    TextField("Access Key ID", text: $configService.config.s3AccessKeyId)
                    SecureField("Secret Key", text: $configService.config.s3SecretKey)
                    TextField("Endpoint", text: $configService.config.s3Endpoint)
                    TextField("Region", text: $configService.config.s3Region)
                    TextField("Bucket Name", text: $configService.config.s3BucketName)
                    
                    HStack {
                        Button("Backup Now") {
                            relayManager.runBackupToCloud(config: configService.config)
                        }
                        .disabled(!relayManager.isRunning)
                        
                        Spacer()
                        
                        Button("Restore Now") {
                            relayManager.runRestoreFromCloud(config: configService.config)
                        }
                        .disabled(relayManager.isRunning)
                        .foregroundColor(.red)
                    }
                    .padding(.vertical, 4)
                }
            } footer: {
               Text("Cloud backup is the recommended way to keep your data safe and synced.")
            }

            #if os(macOS)
            Section("Local Export / Import") {
                Button("Export Database Backup (.zip)") { exportBackup() }
                Button("Import Database Backup (.zip)") { importBackup() }
                
                Divider()
                
                Button("Backup Blossom Media (.zip)") { backupBlossom() }
                Button("Import Blossom Media (.zip)") { importBlossom() }
            } footer: {
                Text("Local backup is currently available on macOS.")
            }
            #endif

            if !backupStatusMessage.isEmpty {
                Section("Status") {
                    Text(backupStatusMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func exportBackup() {
        #if os(macOS)
        let panel = NSSavePanel()
        panel.title = "Export Relay Backup"
        panel.nameFieldStringValue = "haven-backup.zip"
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        isExporting = true
        backupStatusMessage = "Exporting..."
        relayManager.runBackupExport(config: configService.config, outputPath: url.path) { [self] success in
            Task { @MainActor in
                isExporting = false
                backupStatusMessage = success ? "Export complete: \(url.lastPathComponent)" : "Export failed. Check logs."
            }
        }
        #else
        return
        #endif
    }

    private func importBackup() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.title = "Import Relay Backup"
        panel.allowedContentTypes = [.zip]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        isImportingBackup = true
        backupStatusMessage = "Importing..."
        relayManager.runBackupRestore(config: configService.config, inputPath: url.path) { [self] success in
            Task { @MainActor in
                isImportingBackup = false
                backupStatusMessage = success ? "Import complete: \(url.lastPathComponent)" : "Import failed. Check logs."
            }
        }
        #endif
    }
    
    private func backupBlossom() {
        #if os(macOS)
        let panel = NSSavePanel()
        panel.title = "Back up Blossom Data"
        panel.nameFieldStringValue = "blossom-backup.zip"
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        
        guard panel.runModal() == .OK, let url = panel.url else { return }
        
        isBackingUpBlossom = true
        // Clear status from other backup ops
        backupStatusMessage = "Backing up Blossom media..."
        
        relayManager.runBlossomExportWithExtensions(config: configService.config, outputPath: url.path) { [self] success in
            Task { @MainActor in
                isBackingUpBlossom = false
                backupStatusMessage = success ? "Blossom backup complete: \(url.lastPathComponent)" : "Blossom backup failed."
            }
        }
        #endif
    }
    
    private func importBlossom() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.title = "Import Blossom Data"
        panel.allowedContentTypes = [.zip]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        
        guard panel.runModal() == .OK, let url = panel.url else { return }
        
        isImportingBackup = true
        backupStatusMessage = "Importing Blossom media..."
        
        relayManager.runBlossomImportStrippingExtensions(config: configService.config, inputPath: url.path) { success in
            Task { @MainActor in
                isImportingBackup = false
                backupStatusMessage = success ? "Blossom import complete." : "Blossom import failed."
            }
        }
        #endif
    }
}

// RelayListEditor and LogsView moved to separate files

