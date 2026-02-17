import SwiftUI

struct SetupWizardView: View {
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var relayManager: RelayProcessManager
    @State private var currentStep = 0
    @State private var npub = ""
    @State private var relayURL = ""
    @State private var dbEngine = "badger"
    let onComplete: () -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "server.rack")
                    .font(.largeTitle)
                    .foregroundColor(.havenPurple)
                VStack(alignment: .leading) {
                    Text("Welcome to Haven")
                        .font(.title2.bold())
                    Text("Let's set up your personal Nostr relay")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding()
            .background(Color.havenPurplePale)
            
            // Progress
            HStack(spacing: 4) {
                ForEach(0..<6) { step in
                    Capsule()
                        .fill(step <= currentStep ? Color.havenPurple : Color.gray.opacity(0.3))
                        .frame(height: 4)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            
            // Content
            ZStack {
                ScrollView {
                    switch currentStep {
                    case 0:
                        WelcomeStep()
                    case 1:
                        IdentityStep(npub: $npub, whitelistedNpubs: $configService.config.whitelistedNpubs)
                    case 2:
                        RelayURLStep(relayURL: $relayURL)
                    case 3:
                        DatabaseStep(dbEngine: $dbEngine)
                    case 4:
                        SetupImportStep(currentStep: $currentStep)
                    case 5:
                        SetupSuccessStep()
                    default:
                        EmptyView()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            // Custom Error Overlay
            if relayManager.showProcessKillAlert {
                Color.black.opacity(0.6)
                    .ignoresSafeArea()

                VStack(spacing: 20) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.orange)

                    VStack(spacing: 6) {
                        Text("Startup Error")
                            .font(.title2.bold())
                            .foregroundColor(.white)

                        Text("Haven didn't shut down correctly. Tap below to fix it automatically.")
                            .multilineTextAlignment(.center)
                            .foregroundColor(.white.opacity(0.9))
                    }

                    HStack(spacing: 12) {
                        Button(action: {
                            relayManager.forceCleanAndRestart()
                        }) {
                            Text("Fix & Restart")
                                .font(.headline)
                                .foregroundColor(.white)
                                .frame(width: 140, height: 36)
                                .background(Color.orange)
                                .cornerRadius(8)
                        }
                        .buttonStyle(.plain)

                        Button(action: {
                            relayManager.showProcessKillAlert = false
                        }) {
                            Text("Close")
                                .font(.headline)
                                .foregroundColor(.white)
                                .frame(width: 80, height: 36)
                                .background(Color.white.opacity(0.2))
                                .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(30)
                .frame(width: 400)
                .background(Color(NSColor.windowBackgroundColor).opacity(0.98))
                .cornerRadius(16)
                .shadow(radius: 20)
                .transition(.scale.combined(with: .opacity))
                .zIndex(100)
            }
            
            Divider()
            
            // Navigation
            HStack {
                if currentStep > 0 {
                    Button("Back") {
                        withAnimation { currentStep -= 1 }
                    }
                }
                
                Spacer()
                
                if currentStep < 5 {
                    // Hide buttons when import is complete (we show Finish Setup button in the content area)
                    if !(currentStep == 4 && relayManager.importCompleted) {
                        Button(currentStep == 4 && relayManager.isImporting ? "Cancel Import" : (currentStep == 4 ? "Skip & Finish" : "Continue")) {
                            if currentStep == 4 && relayManager.isImporting {
                                // Cancel the import
                                relayManager.cancelImport()
                            } else {
                                if currentStep == 3 {
                                    saveIntermediateConfig()
                                }
                                withAnimation { currentStep += 1 }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(currentStep == 4 && relayManager.isImporting ? .red : .havenPurple)
                        .disabled(!canContinue && !(currentStep == 4 && relayManager.isImporting))
                    }
                } else {
                    Button("Launch Haven") {
                        saveAndComplete()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.havenPurple)
                }
            }
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    @Environment(\.dismiss) var dismiss // Add dismiss environment
    
    var canContinue: Bool {
        switch currentStep {
        case 1: return !npub.isEmpty && npub.hasPrefix("npub")
        default: return true
        }
    }
    
    func saveIntermediateConfig() {
        configService.config.ownerNpub = npub
        configService.config.relayURL = relayURL
        configService.config.dbEngine = dbEngine
        configService.save()
    }
    
    func saveAndComplete() {
        configService.config.ownerNpub = npub
        configService.config.relayURL = relayURL
        configService.config.dbEngine = dbEngine
        configService.config.hasCompletedSetup = true
        configService.save()
        onComplete()
        
        // Close the setup window
        dismiss()
    }
}

// MARK: - Steps

struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 12) {
                FeatureRow(
                    icon: "lock.shield",
                    title: "Private Relay",
                    description: "Store drafts and eCash securely"
                )
                FeatureRow(
                    icon: "bubble.left.and.bubble.right",
                    title: "Chat Relay",
                    description: "Private DMs with Web of Trust protection"
                )
                FeatureRow(
                    icon: "arrow.up.arrow.down",
                    title: "Inbox/Outbox",
                    description: "Manage tagged notes and public posts"
                )
                FeatureRow(
                    icon: "photo.stack",
                    title: "Blossom Media",
                    description: "Host your images and videos"
                )
            }
        }
        .padding()
    }
}

struct IdentityStep: View {
    @Binding var npub: String
    @Binding var whitelistedNpubs: [String]
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "person.badge.key")
                .font(.system(size: 48))
                .foregroundColor(.havenPurple)
            
            Text("Your Nostr Identity")
                .font(.title2.bold())
            
            Text("Enter your public key (npub) to identify yourself as the relay owner")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            TextField("npub1...", text: $npub)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 350)
            
            if !npub.isEmpty && !npub.hasPrefix("npub") {
                Label("Must be a valid npub (starts with 'npub')", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
            
            Divider()
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Whitelisted Npubs (Optional)")
                    .font(.headline)
                Text("Add other npubs that can write to your relay")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                NpubListEditor(npubs: $whitelistedNpubs)
                    .frame(height: 150)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                    )
            }
            .frame(maxWidth: 450)
        }
        .padding()
    }
}

struct RelayURLStep: View {
    @Binding var relayURL: String
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "globe")
                .font(.system(size: 48))
                .foregroundColor(.havenPurple)
            
            Text("Relay URL")
                .font(.title2.bold())
            
            Text("Enter the public URL where your relay will be accessible")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            TextField("relay.example.com", text: $relayURL)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 350)
            
            Text("Leave blank if running locally only")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
    }
}

struct DatabaseStep: View {
    @Binding var dbEngine: String
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "externaldrive")
                .font(.system(size: 48))
                .foregroundColor(.havenPurple)
            
            Text("Database Engine")
                .font(.title2.bold())
            
            Text("Choose how to store your relay data")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            VStack(spacing: 12) {
                DatabaseOption(
                    selected: $dbEngine,
                    value: "badger",
                    title: "BadgerDB",
                    description: "Pre-allocates ~11GB of disk space for high performance. Recommended for most users."
                )
                DatabaseOption(
                    selected: $dbEngine,
                    value: "lmdb",
                    title: "LMDB",
                    description: "Uses sparse files (grows as needed). Faster on NVMe drives, but may require tuning."
                )
                
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                    Text("This choice is permanent. Switching later requires a full reset.")
                        .font(.caption)
                }
                .foregroundColor(.orange)
                .padding(.top, 4)
            }
            .frame(maxWidth: 350)
        }
        .padding()
    }
}

struct SetupImportStep: View {
    @Binding var currentStep: Int // Auto-advance binding
    @EnvironmentObject var relayManager: RelayProcessManager
    @EnvironmentObject var configService: ConfigService
    
    var body: some View {
        VStack(spacing: 0) { // Reduced spacing
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 36)) // Smaller icon
                .foregroundColor(.havenPurple)
                .padding(.top, 10)
            
            VStack(spacing: 4) {
                Text("Import Your Data")
                    .font(.title3.bold()) // Smaller title
                Text("Restore from backup or pull from relays")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.vertical, 10)
            
            VStack(spacing: 12) {
                if relayManager.isImporting || relayManager.importCompleted {
                     // Loading state (keep as is, it's compact enough)
                     // ... (omitted for brevity, assume previous logic or copy if needed. 
                     // actually I need to copy the *entire* block to replace it safely).
                     
                    VStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(relayManager.importCompleted ? "Done!" : "Importing...")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("\(Int(relayManager.importProgress * 100))%")
                                    .font(.caption.monospaced())
                                    .foregroundColor(.havenPurple)
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
                        .frame(maxWidth: 280)
                        
                        if !relayManager.importCompleted {
                            Text(relayManager.importStatusMessage)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .frame(height: 30)
                        }
                        
                        if relayManager.importCompleted {
                            Button(action: {
                                withAnimation {
                                    currentStep += 1
                                }
                            }) {
                                Label("Finish Setup", systemImage: "checkmark.circle.fill")
                                    .font(.headline)
                                    .padding(.vertical, 10)
                                    .frame(maxWidth: .infinity)
                                    .background(Color.green)
                                    .foregroundColor(.white)
                                    .cornerRadius(8)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding()
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(12)
                    
                } else {
                    // Selection State
                    VStack(alignment: .leading, spacing: 16) { // Increased spacing
                        DatePicker("Start Date", selection: Binding(
                            get: {
                                let formatter = DateFormatter()
                                formatter.dateFormat = "yyyy-MM-dd"
                                return formatter.date(from: configService.config.importStartDate) ?? Date()
                            },
                            set: {
                                let formatter = DateFormatter()
                                formatter.dateFormat = "yyyy-MM-dd"
                                configService.config.importStartDate = formatter.string(from: $0)
                            }
                        ), displayedComponents: .date)
                        .font(.body) // Restore font size
                        
                        Divider()
                        
                        Text("Seed Relays")
                            .font(.headline) // Restore font size
                        
                        RelayListEditor(relays: $configService.config.importSeedRelays)
                            .frame(height: 140) // Increased height
                            .background(Color(NSColor.controlBackgroundColor)) // Ensure background covers anything behind
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                            )
                            .clipped() // Prevent overflow
                    }
                    .padding() // Default padding
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(8)
                    
                    Button(action: {
                        configService.save()
                        let config = configService.config
                        relayManager.importNotes(config: config)
                    }) {
                        Label("Start Initial Import", systemImage: "arrow.down.circle.fill")
                            .font(.headline)
                            .padding() // Default padding
                            .frame(maxWidth: .infinity)
                            .background(Color.havenPurple)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                    }
                    .buttonStyle(.plain)
                    
                    HStack {
                        Rectangle().fill(Color.gray.opacity(0.3)).frame(height: 1)
                        Text("OR")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Rectangle().fill(Color.gray.opacity(0.3)).frame(height: 1)
                    }
                    .padding(.vertical, 8)
                    
                    Button(action: {
                        // Activate app to prevent menu dismissal when Finder opens
                        NSApp.activate(ignoringOtherApps: true)
                        showingFileImporter = true
                    }) {
                        Label("Restore from Backup", systemImage: "externaldrive.fill")
                            .font(.headline)
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(Color.secondary.opacity(0.1))
                            .foregroundColor(.primary)
                            .cornerRadius(12)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 350) // Increased width
            
            Spacer()
        }
        .padding()
        .alert("Port Already in Use", isPresented: $relayManager.isPortConflict) {
            Button("Retry", role: .none) {
                // Clear state and retry import
                relayManager.isPortConflict = false
                let config = configService.config
                relayManager.importNotes(config: config)
            }
            
            Button("Change Port", role: .none) {
                // Go back to relay step
                relayManager.isPortConflict = false
                relayManager.cancelImport()
                withAnimation {
                    currentStep = 2 // RelayURLStep is index 2
                }
            }
            
            Button("Cancel", role: .cancel) {
                relayManager.isPortConflict = false
                relayManager.cancelImport()
            }
        } message: {
            Text("Port \(configService.config.relayPort) is currently in use by another process. You can either stop that process manually or choose a different port for Haven.")
        }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.zip, .json],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                restoreBackup(from: url)
            case .failure(let error):
                self.restoreError = error.localizedDescription
                self.showRestoreError = true
            }
        }
        .alert("Restore Failed", isPresented: $showRestoreError, actions: {
            Button("OK", role: .cancel) { }
        }, message: {
            Text(restoreError ?? "Unknown error")
        })
        .sheet(isPresented: $isRestoring) {
            VStack(spacing: 20) {
                ProgressView("Restoring Backup...")
                Text("This may take a few moments.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(40)
        }
    }
    
    @State private var showingFileImporter = false
    @State private var isRestoring = false
    @State private var restoreError: String?
    @State private var showRestoreError = false
    
    private func restoreBackup(from url: URL) {
        isRestoring = true
        
        guard url.startAccessingSecurityScopedResource() else {
            self.restoreError = "Permission denied to access the file."
            self.showRestoreError = true
            self.isRestoring = false
            return
        }
        
        defer { url.stopAccessingSecurityScopedResource() }
        
        // Copy file to temporary directory so the helper process can access it
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent(url.lastPathComponent)
        
        do {
            if FileManager.default.fileExists(atPath: tempFile.path) {
                try FileManager.default.removeItem(at: tempFile)
            }
            try FileManager.default.copyItem(at: url, to: tempFile)
        } catch {
            self.restoreError = "Failed to copy backup file: \(error.localizedDescription)"
            self.showRestoreError = true
            self.isRestoring = false
            return
        }
        
        // Save current config first to ensure we have a base
        configService.save()
        
        RelayProcessManager.shared.runBackupRestore(config: configService.config, inputPath: tempFile.path) { [self] success in
            // Cleanup temp file
            try? FileManager.default.removeItem(at: tempFile)

            Task { @MainActor in
                self.isRestoring = false
                if success {
                    configService.reload()

                    withAnimation {
                        currentStep += 1
                    }
                } else {
                    self.restoreError = "Failed to restore backup. Check logs for details."
                    self.showRestoreError = true
                }
            }
        }
    }
}

struct SetupSuccessStep: View {
    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 80))
                .foregroundColor(.green)
            
            VStack(spacing: 12) {
                Text("You're All Set!")
                    .font(.title.bold())
                Text("Your Haven relay is configured and ready to go.")
                    .font(.title3)
                    .foregroundColor(.secondary)
            }
            
            VStack(alignment: .leading, spacing: 16) {
                SuccessBullet(icon: "bolt.fill", text: "Your relay is now your source of truth.")
                SuccessBullet(icon: "checkmark.shield.fill", text: "End-to-end encrypted DMs are enabled.")
                SuccessBullet(icon: "photo.fill", text: "Blossom media hosting is active.")
            }
            .padding(.top)
            
            Spacer()
        }
        .padding()
    }
}

// MARK: - Components

struct FeatureRow: View {
    let icon: String
    let title: String
    let description: String
    
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.havenPurple)
                .frame(width: 40)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
    }
}

struct SuccessBullet: View {
    let icon: String
    let text: String
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(.havenPurple)
            Text(text)
                .font(.subheadline)
        }
    }
}

struct DatabaseOption: View {
    @Binding var selected: String
    let value: String
    let title: String
    let description: String
    
    var body: some View {
        Button(action: { selected = value }) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        Text(description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: selected == value ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(selected == value ? .havenPurple : .secondary)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(selected == value ? Color.havenPurple : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }
}
