import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var relayManager: RelayProcessManager
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var statsService: StatsService
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // MARK: - Relays List
                VStack(alignment: .leading, spacing: 8) {
                    Text("Relays")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                    
                    VStack(spacing: 1) {
                        RelayRow(
                            name: "Outbox",
                            subtitle: "Public notes",
                            icon: "arrow.up.doc",
                            uri: configService.config.nostrURL,
                            endpoint: ""
                        )
                        
                        RelayRow(
                            name: "Private",
                            subtitle: "Drafts & eCash",
                            icon: "lock.fill",
                            uri: configService.config.nostrURL,
                            endpoint: "/private"
                        )
                        
                        RelayRow(
                            name: "Inbox",
                            subtitle: "Tagged notes",
                            icon: "arrow.down.doc",
                            uri: configService.config.nostrURL,
                            endpoint: "/inbox"
                        )
                        
                        RelayRow(
                            name: "Chat",
                            subtitle: "Private DMs",
                            icon: "bubble.left.and.bubble.right",
                            uri: configService.config.nostrURL,
                            endpoint: "/chat"
                        )
                        
                        RelayRow(
                            name: "Blossom",
                            subtitle: "Media Storage",
                            icon: "photo.stack",
                            uri: configService.config.webURL,
                            endpoint: ""
                        )
                    }
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(8)
                    .padding(.horizontal)
                }


                // MARK: - Statistics
                VStack(alignment: .leading, spacing: 8) {
                    Text("Statistics")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                    
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        StatsCard(title: "Total Notes", value: "\(statsService.loadedNotesCount)", icon: "doc.text.fill", color: .havenPurple, isLoading: statsService.isUpdatingCount && statsService.loadedNotesCount == 0)
                        StatsCard(title: "Storage Used", value: statsService.formattedStorageSize, icon: "internaldrive.fill", color: .blue)
                        StatsCard(title: "Blossom Storage", value: statsService.formattedBlossomSize, icon: "server.rack", color: .green)
                        StatsCard(title: "Media Cache", value: statsService.formattedCacheSize, icon: "photo.stack.fill", color: .orange)
                    }
                    .padding(.horizontal)
                }
                
                // MARK: - Actions
                HStack(spacing: 12) {
                    ActionButton(icon: "safari", title: "Browser") {
                        if let url = URL(string: configService.config.webURL) {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    
                    ActionButton(icon: "arrow.down.circle", title: "Import") {
                        let config = configService.config
                        relayManager.importNotes(config: config)
                    }
                }
                .padding(.horizontal)
                
                .padding(.horizontal)
            }
            .padding(.vertical)
        }
        .onAppear {
            // refreshStats without a URL only updates local disk sizes (storage, blossom, cache)
            statsService.refreshStats()
        }
        .onChange(of: relayManager.isBooting) { oldValue, newValue in
            // When booting finishes, refresh the full stats including remote relay counts
            if !newValue && relayManager.isRunning {
                let urlString = configService.config.relayURL.isEmpty ? "localhost:\(configService.config.relayPort)" : configService.config.relayURL
                statsService.refreshStats(relayURLString: urlString)
            }
        }
        .onChange(of: relayManager.importCompleted) { oldValue, newValue in
            if newValue {
                let urlString = configService.config.relayURL.isEmpty ? "localhost:\(configService.config.relayPort)" : configService.config.relayURL
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    statsService.refreshStats(relayURLString: urlString)
                }
            }
        }
    }
}


struct RelayRow: View {
    let name: String
    let subtitle: String
    let icon: String
    let uri: String
    let endpoint: String
    
    var fullURI: String {
        return uri + endpoint
    }
    
    var body: some View {
        HStack {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.havenPurple)
                .frame(width: 28)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 13, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Text(fullURI)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.havenPurplePale)
                .cornerRadius(4)
                
            Button(action: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(fullURI, forType: .string)
            }) {
                Image(systemName: "doc.on.doc")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.leading, 8)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(NSColor.controlBackgroundColor))
    }
}

struct ActionButton: View {
    let icon: String
    let title: String
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.white)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                LinearGradient(
                    gradient: Gradient(colors: [.havenPurple, .havenPurpleDark]),
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
}

struct StatsCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    var isLoading: Bool = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(color)
                    .font(.system(size: 16))
                Spacer()
            }
            
            VStack(alignment: .leading, spacing: 2) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.8, anchor: .leading)
                        .frame(height: 24)
                } else {
                    Text(value)
                        .font(.system(size: 20, weight: .bold))
                }
                Text(title)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }
}
