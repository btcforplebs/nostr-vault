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
                ForEach(0..<8) { step in
                    Capsule()
                        .fill(step <= currentStep ? Color.havenPurple : Color.gray.opacity(0.3))
                        .frame(height: 4)
                        .animation(
                            .spring(response: 0.4, dampingFraction: 0.7)
                                .delay(Double(step) * 0.04),
                            value: currentStep
                        )
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            
            // Content
            ZStack {
                ScrollView {
                    Group {
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
                            SetupRestoreNotesStep(currentStep: $currentStep)
                        case 6:
                            SetupRestoreMediaStep(currentStep: $currentStep)
                        case 7:
                            SetupSuccessStep()
                        default:
                            EmptyView()
                        }
                    }
                    .id(currentStep)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            // Custom Error Overlay
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

                        Text("A previous Haven process is still running. Run the following command in Terminal to stop it, then relaunch the app.")
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
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("pkill -9 haven", forType: .string)
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
            
            Divider()
            
            // Navigation
            HStack {
                if currentStep > 0 {
                    Button("Back") {
                        currentStep -= 1
                    }
                }
                
                Spacer()
                
                if currentStep < 7 {
                    // Hide buttons when import is complete (we show Continue button in the content area)
                    if !(currentStep == 4 && relayManager.importCompleted) {
                        Button(navButtonLabel) {
                            if currentStep == 4 && relayManager.isImporting {
                                relayManager.cancelImport()
                            } else {
                                if currentStep == 3 {
                                    saveIntermediateConfig()
                                }
                                currentStep += 1
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
    
    var navButtonLabel: String {
        if currentStep == 4 && relayManager.isImporting {
            return "Cancel Import"
        } else if currentStep == 4 || currentStep == 5 || currentStep == 6 {
            return "Skip"
        } else {
            return "Continue"
        }
    }

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
        FloatingArrowController.shared.dismiss()

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
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 12) {
                FeatureRow(
                    icon: "lock.shield",
                    title: "Private Relay",
                    description: "Store drafts and eCash securely"
                )
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 16)
                .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.05), value: appeared)

                FeatureRow(
                    icon: "bubble.left.and.bubble.right",
                    title: "Chat Relay",
                    description: "Private DMs with Web of Trust protection"
                )
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 16)
                .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.12), value: appeared)

                FeatureRow(
                    icon: "arrow.up.arrow.down",
                    title: "Inbox/Outbox",
                    description: "Manage tagged notes and public posts"
                )
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 16)
                .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.19), value: appeared)

                FeatureRow(
                    icon: "photo.stack",
                    title: "Blossom Media",
                    description: "Host your images and videos"
                )
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 16)
                .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.26), value: appeared)
            }
        }
        .padding()
        .onAppear { appeared = true }
    }
}

struct IdentityStep: View {
    @Binding var npub: String
    @Binding var whitelistedNpubs: [String]
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "person.badge.key")
                .font(.system(size: 48))
                .foregroundColor(.havenPurple)
                .scaleEffect(appeared ? 1.0 : 0.5)
                .opacity(appeared ? 1 : 0)
                .animation(.spring(response: 0.5, dampingFraction: 0.7).delay(0.05), value: appeared)

            Text("Your Nostr Identity")
                .font(.title2.bold())
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 12)
                .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.1), value: appeared)

            Text("Enter your public key (npub) to identify yourself as the relay owner")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 12)
                .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.15), value: appeared)

            TextField("npub1...", text: $npub)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 350)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 10)
                .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.2), value: appeared)

            if !npub.isEmpty && !npub.hasPrefix("npub") {
                Label("Must be a valid npub (starts with 'npub')", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundColor(.orange)
            }

            Divider()
                .opacity(appeared ? 1 : 0)
                .animation(.easeIn(duration: 0.3).delay(0.25), value: appeared)

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
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 10)
            .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.3), value: appeared)
        }
        .padding()
        .onAppear { appeared = true }
    }
}

struct RelayURLStep: View {
    @Binding var relayURL: String
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "globe")
                .font(.system(size: 48))
                .foregroundColor(.havenPurple)
                .scaleEffect(appeared ? 1.0 : 0.5)
                .opacity(appeared ? 1 : 0)
                .animation(.spring(response: 0.5, dampingFraction: 0.7).delay(0.05), value: appeared)

            Text("Relay URL")
                .font(.title2.bold())
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 12)
                .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.1), value: appeared)

            Text("Enter the public URL where your relay will be accessible")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 12)
                .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.15), value: appeared)

            TextField("relay.example.com", text: $relayURL)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 350)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 10)
                .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.2), value: appeared)

            Text("Leave blank if running locally only")
                .font(.caption)
                .foregroundColor(.secondary)
                .opacity(appeared ? 1 : 0)
                .animation(.easeIn(duration: 0.3).delay(0.25), value: appeared)
        }
        .padding()
        .onAppear { appeared = true }
    }
}

struct DatabaseStep: View {
    @Binding var dbEngine: String
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "externaldrive")
                .font(.system(size: 48))
                .foregroundColor(.havenPurple)
                .scaleEffect(appeared ? 1.0 : 0.5)
                .opacity(appeared ? 1 : 0)
                .animation(.spring(response: 0.5, dampingFraction: 0.7).delay(0.05), value: appeared)

            Text("Database Engine")
                .font(.title2.bold())
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 12)
                .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.1), value: appeared)

            Text("Choose how to store your relay data")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 12)
                .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.15), value: appeared)

            VStack(spacing: 12) {
                DatabaseOption(
                    selected: $dbEngine,
                    value: "badger",
                    title: "BadgerDB",
                    description: "Pre-allocates ~11GB of disk space for high performance. Recommended for most users."
                )
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 10)
                .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.2), value: appeared)

                DatabaseOption(
                    selected: $dbEngine,
                    value: "lmdb",
                    title: "LMDB",
                    description: "Uses sparse files (grows as needed). Faster on NVMe drives, but may require tuning."
                )
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 10)
                .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.27), value: appeared)

                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                    Text("This choice is permanent. Switching later requires a full reset.")
                        .font(.caption)
                }
                .foregroundColor(.orange)
                .padding(.top, 4)
                .opacity(appeared ? 1 : 0)
                .animation(.easeIn(duration: 0.3).delay(0.35), value: appeared)
            }
            .frame(maxWidth: 350)
        }
        .padding()
        .onAppear { appeared = true }
    }
}

struct SetupImportStep: View {
    @Binding var currentStep: Int
    @EnvironmentObject var relayManager: RelayProcessManager
    @EnvironmentObject var configService: ConfigService

    @State private var appeared = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 48))
                .foregroundColor(.havenPurple)
                .scaleEffect(appeared ? 1.0 : 0.5)
                .opacity(appeared ? 1 : 0)
                .animation(.spring(response: 0.5, dampingFraction: 0.7).delay(0.05), value: appeared)

            Text("Import from Relays")
                .font(.title2.bold())
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 12)
                .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.1), value: appeared)

            Text("Pull your notes from external relays")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 12)
                .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.15), value: appeared)

            VStack(spacing: 12) {
                if relayManager.isImporting || relayManager.importCompleted {
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
                                currentStep += 1
                            }) {
                                Label("Continue", systemImage: "arrow.right.circle.fill")
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
                    VStack(alignment: .leading, spacing: 16) {
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
                        .font(.body)

                        Divider()

                        Text("Seed Relays")
                            .font(.headline)

                        RelayListEditor(relays: $configService.config.importSeedRelays)
                            .frame(height: 140)
                            .background(Color(NSColor.controlBackgroundColor))
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                            )
                            .clipped()
                    }
                    .padding()
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(8)

                    Button(action: {
                        configService.save()
                        let config = configService.config
                        relayManager.importNotes(config: config)
                    }) {
                        Label("Start Import", systemImage: "arrow.down.circle.fill")
                            .font(.headline)
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(Color.havenPurple)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 350)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 10)
            .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.2), value: appeared)
        }
        .padding()
        .onAppear { appeared = true }
        .alert("Port Already in Use", isPresented: $relayManager.isPortConflict) {
            Button("Retry", role: .none) {
                relayManager.isPortConflict = false
                let config = configService.config
                relayManager.importNotes(config: config)
            }

            Button("Change Port", role: .none) {
                relayManager.isPortConflict = false
                relayManager.cancelImport()
                currentStep = 2
            }

            Button("Cancel", role: .cancel) {
                relayManager.isPortConflict = false
                relayManager.cancelImport()
            }
        } message: {
            Text("Port \(configService.config.relayPort) is currently in use by another process. You can either stop that process manually or choose a different port for Haven.")
        }
    }
}

struct SetupRestoreNotesStep: View {
    @Binding var currentStep: Int
    @EnvironmentObject var configService: ConfigService

    @State private var appeared = false
    @State private var showingFileImporter = false
    @State private var isRestoring = false
    @State private var restoreCompleted = false
    @State private var restoreError: String?
    @State private var showRestoreError = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "doc.zipper")
                .font(.system(size: 48))
                .foregroundColor(.havenPurple)
                .scaleEffect(appeared ? 1.0 : 0.5)
                .opacity(appeared ? 1 : 0)
                .animation(.spring(response: 0.5, dampingFraction: 0.7).delay(0.05), value: appeared)

            Text("Restore Notes")
                .font(.title2.bold())
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 12)
                .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.1), value: appeared)

            Text("Restore your notes and metadata from a Haven backup")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 12)
                .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.15), value: appeared)

            VStack(spacing: 12) {
                if isRestoring {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Restoring...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(12)
                } else if restoreCompleted {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.title2)
                        Text("Notes restored successfully!")
                            .font(.subheadline.weight(.medium))
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.green.opacity(0.5), lineWidth: 2)
                    )

                    Button(action: {
                        currentStep += 1
                    }) {
                        Label("Continue", systemImage: "arrow.right.circle.fill")
                            .font(.headline)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity)
                            .background(Color.green)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button(action: {
                        NSApp.activate(ignoringOtherApps: true)
                        showingFileImporter = true
                    }) {
                        Label("Choose Backup File", systemImage: "folder")
                            .font(.headline)
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(Color.havenPurple)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                    }
                    .buttonStyle(.plain)

                    Text("Select a Haven backup (.zip) to restore your notes")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: 350)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 10)
            .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.2), value: appeared)
        }
        .padding()
        .onAppear { appeared = true }
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
    }

    private func restoreBackup(from url: URL) {
        isRestoring = true

        guard url.startAccessingSecurityScopedResource() else {
            self.restoreError = "Permission denied to access the file."
            self.showRestoreError = true
            self.isRestoring = false
            return
        }

        defer { url.stopAccessingSecurityScopedResource() }

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

        configService.save()

        RelayProcessManager.shared.runBackupRestore(config: configService.config, inputPath: tempFile.path) { success in
            try? FileManager.default.removeItem(at: tempFile)

            Task { @MainActor in
                self.isRestoring = false
                if success {
                    configService.reload()
                    self.restoreCompleted = true
                } else {
                    self.restoreError = "Failed to restore backup. Check logs for details."
                    self.showRestoreError = true
                }
            }
        }
    }
}

struct SetupRestoreMediaStep: View {
    @Binding var currentStep: Int
    @EnvironmentObject var configService: ConfigService

    @State private var appeared = false
    @State private var showingFileImporter = false
    @State private var isRestoring = false
    @State private var restoreCompleted = false
    @State private var restoreError: String?
    @State private var showRestoreError = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "photo.stack")
                .font(.system(size: 48))
                .foregroundColor(.havenPurple)
                .scaleEffect(appeared ? 1.0 : 0.5)
                .opacity(appeared ? 1 : 0)
                .animation(.spring(response: 0.5, dampingFraction: 0.7).delay(0.05), value: appeared)

            Text("Restore Media")
                .font(.title2.bold())
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 12)
                .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.1), value: appeared)

            Text("Restore your images and videos from a Blossom backup")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 12)
                .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.15), value: appeared)

            VStack(spacing: 12) {
                if isRestoring {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Importing media...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(12)
                } else if restoreCompleted {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.title2)
                        Text("Media restored successfully!")
                            .font(.subheadline.weight(.medium))
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.green.opacity(0.5), lineWidth: 2)
                    )

                    Button(action: {
                        currentStep += 1
                    }) {
                        Label("Continue", systemImage: "arrow.right.circle.fill")
                            .font(.headline)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity)
                            .background(Color.green)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button(action: {
                        NSApp.activate(ignoringOtherApps: true)
                        showingFileImporter = true
                    }) {
                        Label("Choose Media Archive", systemImage: "folder")
                            .font(.headline)
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(Color.havenPurple)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                    }
                    .buttonStyle(.plain)

                    Text("Select a Blossom backup (.zip) to restore your media files")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: 350)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 10)
            .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.2), value: appeared)
        }
        .padding()
        .onAppear { appeared = true }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.zip],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                restoreMedia(from: url)
            case .failure(let error):
                self.restoreError = error.localizedDescription
                self.showRestoreError = true
            }
        }
        .alert("Import Failed", isPresented: $showRestoreError, actions: {
            Button("OK", role: .cancel) { }
        }, message: {
            Text(restoreError ?? "Unknown error")
        })
    }

    private func restoreMedia(from url: URL) {
        isRestoring = true

        guard url.startAccessingSecurityScopedResource() else {
            self.restoreError = "Permission denied to access the file."
            self.showRestoreError = true
            self.isRestoring = false
            return
        }

        defer { url.stopAccessingSecurityScopedResource() }

        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent(url.lastPathComponent)

        do {
            if FileManager.default.fileExists(atPath: tempFile.path) {
                try FileManager.default.removeItem(at: tempFile)
            }
            try FileManager.default.copyItem(at: url, to: tempFile)
        } catch {
            self.restoreError = "Failed to copy media archive: \(error.localizedDescription)"
            self.showRestoreError = true
            self.isRestoring = false
            return
        }

        RelayProcessManager.shared.runBlossomImportStrippingExtensions(config: configService.config, inputPath: tempFile.path) { success in
            try? FileManager.default.removeItem(at: tempFile)

            Task { @MainActor in
                self.isRestoring = false
                if success {
                    self.restoreCompleted = true
                } else {
                    self.restoreError = "Failed to import media. Check logs for details."
                    self.showRestoreError = true
                }
            }
        }
    }
}

struct SetupSuccessStep: View {
    @State private var showContent = false

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 80))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.green, .green.opacity(0.7)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .scaleEffect(showContent ? 1.0 : 0.3)
                .opacity(showContent ? 1.0 : 0.0)
                .animation(.spring(response: 0.6, dampingFraction: 0.5).delay(0.1), value: showContent)

            VStack(spacing: 12) {
                Text("You're All Set!")
                    .font(.system(.title, design: .rounded).bold())
                    .opacity(showContent ? 1.0 : 0.0)
                    .offset(y: showContent ? 0 : 20)
                    .animation(.spring(response: 0.6, dampingFraction: 0.7).delay(0.3), value: showContent)

                Text("Your Haven relay is configured and ready to go.")
                    .font(.title3)
                    .foregroundColor(.secondary)
                    .opacity(showContent ? 1.0 : 0.0)
                    .offset(y: showContent ? 0 : 15)
                    .animation(.spring(response: 0.6, dampingFraction: 0.7).delay(0.4), value: showContent)
            }

            VStack(alignment: .leading, spacing: 16) {
                SuccessBullet(icon: "bolt.fill", text: "Your relay is now your source of truth.")
                SuccessBullet(icon: "checkmark.shield.fill", text: "End-to-end encrypted DMs are enabled.")
                SuccessBullet(icon: "photo.fill", text: "Blossom media hosting is active.")
            }
            .padding(.top)
            .opacity(showContent ? 1.0 : 0.0)
            .offset(y: showContent ? 0 : 10)
            .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.6), value: showContent)

            Spacer()

            // Subtle in-window hint (the real arrow floats outside)
            Text("Look for the relay icon in your menu bar!")
                .font(.system(.subheadline, design: .rounded))
                .foregroundColor(.havenPurple.opacity(0.8))
                .opacity(showContent ? 1.0 : 0.0)
                .animation(.easeIn(duration: 0.5).delay(1.2), value: showContent)
                .padding(.bottom, 20)
        }
        .padding()
        .onAppear {
            showContent = true
            // Show the floating arrow outside the window after content settles
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                FloatingArrowController.shared.show()
            }
        }
        .onDisappear {
            FloatingArrowController.shared.dismiss()
        }
    }
}

// MARK: - Components

struct FeatureRow: View {
    let icon: String
    let title: String
    let description: String
    @State private var isHovered = false
    
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.havenPurple)
                .frame(width: 40)
                .scaleEffect(isHovered ? 1.1 : 1.0)
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isHovered)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(.headline, design: .rounded))
                Text(description)
                    .font(.caption)
                    .foregroundColor(isHovered ? .primary : .secondary)
            }
            
            Spacer()
        }
        .padding()
        .background(isHovered ? Color.havenPurplePale : Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
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
    @State private var isHovered = false
    
    var body: some View {
        Button(action: { selected = value }) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(.headline, design: .rounded))
                    Text(description)
                        .font(.caption)
                        .foregroundColor(selected == value ? .primary : .secondary)
                }
                Spacer()
                Image(systemName: selected == value ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(selected == value ? .havenPurple : (isHovered ? .primary : .secondary))
                    .scaleEffect(selected == value ? 1.1 : 1.0)
                    .animation(.spring(response: 0.3, dampingFraction: 0.6), value: selected)
            }
            .padding()
            .background(selected == value ? Color.havenPurplePale.opacity(0.5) : (isHovered ? Color(NSColor.controlBackgroundColor).opacity(0.8) : Color(NSColor.controlBackgroundColor)))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(selected == value ? Color.havenPurple : (isHovered ? Color.gray.opacity(0.5) : Color.clear), lineWidth: 2)
            )
            .scaleEffect(isHovered && selected != value ? 1.01 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
