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
    @State private var selectedTab: SettingsTab = .identity
    @State private var saveTask: Task<Void, Never>?
    @State private var isRestarting = false
    
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
        return configService.config != lastLaunch
    }
    
    enum SettingsTab: String, CaseIterable, Identifiable {
        case identity = "Identity"
        case accessControl = "Access Control"
        case appearance = "Appearance"
        case feed = "Feed Relays"
        case importNotes = "Import"
        case backup = "Backup"
        case blastr = "Blastr"
        case advanced = "Advanced"
        case wallet = "Wallet"
        case logs = "Logs"
        
        var id: String { self.rawValue }
        
        var icon: String {
            switch self {
            case .identity: return "person.badge.key"
            case .accessControl: return "shield.lefthalf.filled"
            case .appearance: return "paintpalette"
            case .feed: return "newspaper"
            case .importNotes: return "square.and.arrow.down"
            case .backup: return "externaldrive.fill"
            case .blastr: return "paperplane"
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
        .frame(width: 800, height: 600)
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
                tabLink(.identity)
                tabLink(.accessControl)
            }
            
            Section("Appearance") {
                tabLink(.appearance)
            }
            
            Section("Relay Configuration") {
                tabLink(.feed)
                tabLink(.blastr)
                tabLink(.importNotes)
                tabLink(.backup)
            }
            
            Section("System") {
                tabLink(.wallet)
                tabLink(.advanced)
                tabLink(.logs)
            }
            
            Section("About") {
                VStack(spacing: 4) {
                    Text("Haven Relay")
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
                            
                        Link("Privacy Policy", destination: URL(string: "https://havenformac.btcforplebs.com/privacy.html")!)
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
        case .identity: return .blue
        case .accessControl: return .green
        case .appearance: return .purple
        case .feed: return .pink
        case .importNotes: return .orange
        case .backup: return .indigo
        case .blastr: return .cyan
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
            case .identity: IdentitySettingsView()
            case .accessControl: AccessControlSettingsView()
            case .appearance: AppearanceSettingsView()
            case .feed: FeedSettingsView()
            case .importNotes: ImportSettingsView()
            case .backup: BackupSettingsView()
            case .blastr: BlastrSettingsView()
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
                Text("Haven Relay v\(appVersion)")
                    .font(.caption.bold())
                Text("Abuse Reporting: npub1vxlh...g0nvx")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
                    .onTapGesture {
                        PlatformClipboard.copy("npub1vxlhjzeqjjhmqdy4e8sndt8kzklqlnxzew2mtt8mtakvalsckp3qa0gnvx")
                    }
                Link("Privacy Policy", destination: URL(string: "https://havenformac.btcforplebs.com/privacy.html")!)
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
                        .background(Color.platformControlBackground)
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
                            HStack(spacing: 8) {
                                Button(action: { showUpdateKey = true }) {
                                    Text("Update")
                                        .font(.caption)
                                }
                                .buttonStyle(.bordered)
                                Button(role: .destructive) {
                                    configService.config.ownerNcryptsec = ""
                                    configService.config.ownerNsec = ""
                                    configService.save()
                                } label: {
                                    Text("Clear")
                                        .font(.caption)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        .padding(8)
                        .background(Color.platformControlBackground)
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
                            HStack(spacing: 8) {
                                Button(action: { showUpdateKey = true }) {
                                    Text("Update")
                                        .font(.caption)
                                }
                                .buttonStyle(.bordered)
                                Button(role: .destructive) {
                                    configService.config.ownerNsec = ""
                                    configService.save()
                                } label: {
                                    Text("Clear")
                                        .font(.caption)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        .padding(8)
                        .background(Color.platformControlBackground)
                        .cornerRadius(8)

                        Text("This key is stored in plaintext. For security, update it to encrypt with NIP-49.")
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
        .groupedFormStyleCompat()
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(isPresented: $showUpdateKey) {
            updateKeySheet
        }
    }

    private var updateKeySheet: some View {
        Group {
            #if os(iOS)
            NavigationView {
                updateKeyForm
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
            #else
            VStack(spacing: 0) {
                Text(configService.config.ownerNcryptsec.isEmpty && configService.config.ownerNsec.isEmpty ? "Import Private Key" : "Update Private Key")
                    .font(.headline)
                    .padding()
                
                Divider()
                
                updateKeyForm
                
                Divider()
                
                HStack {
                    Spacer()
                    Button("Cancel") {
                        resetForm()
                        showUpdateKey = false
                    }
                    .keyboardShortcut(.cancelAction)
                    
                    Button(configService.config.ownerNcryptsec.isEmpty && configService.config.ownerNsec.isEmpty ? "Import" : "Update") {
                        savePrivateKey()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(newNsec.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || newPassword.isEmpty)
                }
                .padding()
            }
            .frame(width: 450, height: 500)
            #endif
        }
    }

    private var updateKeyForm: some View {
        Form {
            Section("Enter Private Key") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("nsec (Nostr Secret Key)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $newNsec)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 80)
                            .padding(4)
                            .background(Color.platformControlBackground)
                            .cornerRadius(6)
                            .autocorrectionDisabled()
                            .disableAutocorrection(true)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.asciiCapable)
                            #endif
                        
                        HStack {
                            Spacer()
                            VStack {
                                Button(action: pastePrivateKey) {
                                    Image(systemName: "doc.on.clipboard")
                                        .font(.system(size: 14))
                                        .foregroundColor(.secondary)
                                        .padding(8)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(4)
                    }
                    
                    Text("Long press or tap the clipboard icon to paste your private key")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Section("Set Password (NIP-49 Encryption)") {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        SecureField("Password", text: $newPassword)
                        SecureField("Confirm Password", text: $confirmPassword)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Label("Password will be securely stored in your Keychain", systemImage: "lock.fill")
                            .font(.caption)
                            .foregroundColor(.green)
                        Text("Haven uses your password to automatically decrypt your key when signing notes. You won't need to enter it each time.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 4)
                }
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
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("Private key updated successfully!")
                                .font(.caption)
                                .fontWeight(.semibold)
                        }
                        HStack {
                            Image(systemName: "lock.fill")
                                .font(.caption)
                                .foregroundColor(.green)
                            Text("Password saved to Keychain — Haven will use it automatically when signing notes")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
        .groupedFormStyleCompat()
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
            configService.config.ownerNcryptsec = try NIP49Service.encrypt(nsec: nsecTrimmed, password: newPassword)
            configService.config.ownerNsec = ""
            // Store password in Keychain for auto-signing
            _ = NIP49Service.storePasswordInKeychain(newPassword)
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
    
    private func pastePrivateKey() {
        #if os(iOS)
        if let pasteString = UIPasteboard.general.string {
            newNsec = pasteString
        }
        #else
        if let pasteString = NSPasteboard.general.string(forType: .string) {
            newNsec = pasteString
        }
        #endif
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

            Form {
                content(for: selectedList)
            }
            .groupedFormStyleCompat()
            .padding()
        }
    }
    #endif

    #if os(iOS)
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
        .groupedFormStyleCompat()
    }
    #endif

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

    #if os(iOS)
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
    #endif

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


struct AdvancedSettingsView: View {
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var relayManager: RelayProcessManager
    @State private var showResetConfirmation = false
    #if os(iOS)
    @StateObject private var macSyncService = MacRelaySyncService.shared
    #endif
    
    var body: some View {
        Form {
            #if os(iOS)
            macRelaySyncSection
            #endif
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

    #if os(iOS)
    private var macRelaySyncSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Text("Mac Relay URL")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                TextField("wss://relay.example.com", text: $configService.config.macRelayURL)
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
                
                Text("Enter the WebSocket URL of your always-on Mac Haven relay. The iOS app will sync any notes it missed while backgrounded.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 4)
            
            // Sync status & button
            if !configService.config.macRelayURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        if macSyncService.isSyncing {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
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
                            Text("Last sync: \(lastSync, style: .relative) ago")
                                .font(.caption2)
                                .foregroundColor(.secondary.opacity(0.7))
                        }
                    }
                    
                    Spacer()
                    
                    Button(action: {
                        macSyncService.forceSync()
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                            Text("Sync Now")
                        }
                        .font(.subheadline.bold())
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.havenPurple)
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                    .disabled(macSyncService.isSyncing)
                }
            }
        } header: {
            HStack(spacing: 6) {
                Image(systemName: "desktopcomputer")
                Text("Mac Relay Sync")
            }
        } footer: {
            Text("Connect to your always-on Mac Haven relay to sync notes the iOS app missed while in the background.")
        }
    }
    #endif
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
    @EnvironmentObject var nostrService: NostrService

    @State private var isExportingJSONL = false
    @State private var isImportingJSONL = false
    @State private var isExportingBlossom = false
    @State private var isImportingBlossom = false
    @State private var statusMessage = ""
    @State private var showFileImporter = false
    @State private var showBlossomImporter = false
    @ObservedObject private var mirrorService = MirrorService.shared
    
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
                        Text("Restore notes from a Haven JSONL backup (.zip)")
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

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Mirror from Servers")
                            .font(.body)
                        Text("Download your media from external Blossom mirrors to local storage")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(action: {
                        mirrorService.runMirror(configService: configService, nostrService: nostrService)
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
                                Text("Mirror")
                            }
                        }
                    }
                    .disabled(mirrorService.state == .mirroring || configService.config.blossomMirrors.isEmpty)
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
                        Text("Automatically download your media from mirrors when the relay starts")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("Media Mirroring")
            } footer: {
                Text("Downloads your own Blossom media from configured mirror servers to your local relay for offline access.")
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
        let tempPath = (tempDir as NSString).appendingPathComponent("haven-backup-\(Date().timeIntervalSince1970).zip")
        
        relayManager.runBackupExport(config: configService.config, outputPath: tempPath) { success in
            Task { @MainActor in
                isExportingJSONL = false
                guard success else {
                    statusMessage = "JSONL export failed"
                    clearStatus()
                    return
                }
                #if os(macOS)
                presentSavePanel(title: "Save JSONL Backup", defaultName: "haven-backup.zip", tempPath: tempPath)
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

struct BlastrSettingsView: View {
    @EnvironmentObject var configService: ConfigService
    @State private var newMirrorURL = ""
    
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

            Section {
                // Existing mirrors list
                ForEach(configService.config.blossomMirrors.indices, id: \.self) { index in
                    HStack {
                        Text(configService.config.blossomMirrors[index])
                            .lineLimit(1)
                        Spacer()
                        Button(role: .destructive) {
                            configService.config.blossomMirrors.remove(at: index)
                            configService.save()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.red.opacity(0.6))
                        }
                    }
                }

                // Add new mirror
                HStack {
                    TextField("https://example.com", text: $newMirrorURL)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        #endif

                    Button(action: {
                        let trimmed = newMirrorURL.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            configService.config.blossomMirrors.append(trimmed)
                            configService.save()
                            newMirrorURL = ""
                        }
                    }) {
                        Image(systemName: "plus.circle.fill")
                            .foregroundColor(.green)
                    }
                    .disabled(newMirrorURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } header: {
                Text("Blossom Mirrors")
            } footer: {
                Text("Media uploads are mirrored to these external Blossom servers. Remote users access your media via these mirrors instead of localhost.")
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
                Text("Paste your nostr+walletconnect:// URI here to enable sending Zaps directly from Haven.")
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
                Text("Choose an accent color for the Haven interface. This will change the primary color and gradients across the application.")
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

// RelayListEditor and LogsView moved to separate files

