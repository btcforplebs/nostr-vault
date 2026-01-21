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
                switch currentStep {
                case 0:
                    WelcomeStep()
                case 1:
                    IdentityStep(npub: $npub)
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            
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
        VStack(spacing: 12) {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 48))
                .foregroundColor(.havenPurple)
            
            VStack(spacing: 8) {
                Text("Import Your Data")
                    .font(.title2.bold())
                Text("Would you like to pull your existing notes from other relays?")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            
            VStack(spacing: 16) {
                if relayManager.isImporting || relayManager.importCompleted {
                    VStack(spacing: 16) {
                        // "Great loading bar math" (Gradient bar UI from MenuBarView)
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(relayManager.importCompleted ? "Import Complete!" : "Importing your notes...")
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
                        .frame(maxWidth: 300)
                        
                        // Status Message
                        if !relayManager.importCompleted {
                            Text(relayManager.importStatusMessage)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .frame(height: 35)
                        }
                        
                        // Show Finish Setup button when import is complete
                        if relayManager.importCompleted {
                            Button(action: {
                                withAnimation {
                                    currentStep += 1
                                }
                            }) {
                                Label("Finish Setup", systemImage: "checkmark.circle.fill")
                                    .font(.headline)
                                    .padding()
                                    .frame(maxWidth: .infinity)
                                    .background(Color.green)
                                    .foregroundColor(.white)
                                    .cornerRadius(12)
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 8)
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(12)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
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
                        
                        Divider()
                        
                        Text("Seed Relays")
                            .font(.headline)
                        
                        RelayListEditor(relays: $configService.config.importSeedRelays)
                            .frame(height: 120)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                            )
                    }
                    .padding()
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(8)
                    
                    Button(action: {
                        // Save config and start import
                        configService.save()
                        
                        let config = configService.config
                        relayManager.importNotes(config: config)
                    }) {
                        Label("Start Initial Import", systemImage: "arrow.down.circle.fill")
                            .font(.headline)
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(Color.havenPurple)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                    }
                    .buttonStyle(.plain)
                    
                    Text("This fetches your notes and mentions from configured seed relays.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: 300)
            
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
