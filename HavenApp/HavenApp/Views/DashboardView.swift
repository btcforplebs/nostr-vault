import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var relayManager: RelayProcessManager
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var statsService: StatsService
    
    @State private var isExporting = false
    @State private var isBackingUpBlossom = false
    @State private var exportStatusMessage = ""
    @State private var relaysExpanded = false
    
    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                // MARK: - Relays List
                VStack(alignment: .leading, spacing: 8) {
                    Button(action: {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            relaysExpanded.toggle()
                        }
                    }) {
                        HStack {
                            Text("Relays")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.secondary)
                            Spacer()
                            Image(systemName: relaysExpanded ? "eye.fill" : "eye.slash")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if relaysExpanded {
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
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }


                // MARK: - Statistics
                VStack(alignment: .leading, spacing: 8) {
                    Text("Statistics")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                    
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        StatsCard(title: "Total Notes", value: "\(statsService.loadedNotesCount)", icon: "doc.text.fill", color: .havenPurple, isLoading: statsService.isUpdatingCount && statsService.loadedNotesCount == 0)
                        StatsCard(title: "Storage Used", value: statsService.formattedStorageSize, icon: "internaldrive.fill", color: .blue)
                        StatsCard(title: "Blossom Storage", value: statsService.formattedBlossomSize, icon: "server.rack", color: .green)
                        StatsCard(title: "Media Cache", value: statsService.formattedCacheSize, icon: "photo.stack.fill", color: .orange)
                    }
                    .padding(.horizontal)
                }
                
                // MARK: - Actions
                Spacer(minLength: 8) // Allows the stats to pin to the top and actions to sit further down if there's dead space
                
                VStack(spacing: 6) {
                    HStack(spacing: 8) {
                        ActionButton(icon: "safari", title: "Browser") {
                            if let url = URL(string: configService.config.webURL) {
                                NSWorkspace.shared.open(url)
                            }
                        }

                        ActionButton(icon: "arrow.down.circle", title: "Import Notes") {
                            let config = configService.config
                            relayManager.importNotes(config: config)
                        }
                    }

                    HStack(spacing: 8) {
                        ActionButton(icon: "arrow.up.doc.fill", title: "Export JSONL", isLoading: isExporting) {
                            exportBackup()
                        }
                        .disabled(isExporting || isBackingUpBlossom)

                        ActionButton(icon: "photo.stack", title: "Export Blossom", isLoading: isBackingUpBlossom) {
                            exportBlossom()
                        }
                        .disabled(isExporting || isBackingUpBlossom)
                    }

                    if !exportStatusMessage.isEmpty {
                        Text(exportStatusMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .disabled(!relayManager.isRunning)
                .opacity(relayManager.isRunning ? 1.0 : 0.5)
                .padding(.horizontal)
            }
            .padding(.vertical, 10)
            .frame(minHeight: 350, maxHeight: .infinity, alignment: .top)
        }
        .onAppear {
            // Consolidated refresh:
            // If relay is running, we pass the URL to get BOTH disk stats and network counts.
            // If not running, we pass nil to get ONLY disk stats.
            
            if relayManager.isRunning && !relayManager.isBooting {
                let urlString = configService.config.relayURL.isEmpty ? "localhost:\(configService.config.relayPort)" : configService.config.relayURL
                #if DEBUG
                print("Dashboard: Relay running, requesting full stats refresh from \(urlString)")
                #endif
                statsService.refreshStats(relayURLString: urlString)
            } else if relayManager.state == .booting {
                #if DEBUG
                print("Dashboard: Relay booting, scheduling retry...")
                #endif
                // Initial disk-only fetch while booting
                statsService.refreshStats()
                
                // Retry full fetch after delay
                let urlString = configService.config.relayURL.isEmpty ? "localhost:\(configService.config.relayPort)" : configService.config.relayURL
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                    if relayManager.isRunning {
                        #if DEBUG
                        print("Dashboard: Retrying full stats refresh...")
                        #endif
                        statsService.refreshStats(relayURLString: urlString)
                    }
                }
            } else {
                // Not running, just get disk stats
                #if DEBUG
                print("Dashboard: Relay not running, fetching disk stats only")
                #endif
                statsService.refreshStats()
            }
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
    
    private func exportBackup() {
        let panel = NSSavePanel()
        panel.title = "Export Relay Backup"
        panel.nameFieldStringValue = "haven-backup.zip"
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        isExporting = true
        exportStatusMessage = "Exporting JSONL..."
        relayManager.runBackupExport(config: configService.config, outputPath: url.path) { success in
            Task { @MainActor in
                isExporting = false
                exportStatusMessage = success ? "Export complete" : "Export failed"
                // Clear message after delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    if exportStatusMessage.contains("Export complete") || exportStatusMessage.contains("Export failed") {
                        exportStatusMessage = ""
                    }
                }
            }
        }
    }
    
    private func exportBlossom() {
        let panel = NSSavePanel()
        panel.title = "Export Blossom Media"
        panel.nameFieldStringValue = "blossom-backup.zip"
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        
        guard panel.runModal() == .OK, let url = panel.url else { return }
        
        isBackingUpBlossom = true
        exportStatusMessage = "Exporting Blossom..."
        
        relayManager.runBlossomExportWithExtensions(config: configService.config, outputPath: url.path) { success in
            Task { @MainActor in
                isBackingUpBlossom = false
                exportStatusMessage = success ? "Blossom Export complete" : "Blossom Export failed"
                // Clear message after delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    if exportStatusMessage.contains("Blossom Export") {
                        exportStatusMessage = ""
                    }
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

    @State private var copied = false

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
                withAnimation(.easeInOut(duration: 0.2)) { copied = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    withAnimation(.easeInOut(duration: 0.2)) { copied = false }
                }
            }) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .foregroundColor(copied ? .green : .secondary)
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
    var isLoading: Bool = false
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .colorScheme(.dark) // Make spinner light to contrast with purple button
                        // .tint(.white) // Valid in newer SwiftUI, but colorScheme works for now
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.white)
                }
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
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

    @State private var isHovered = false

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
        .padding(10)
        .background(isHovered ? color.opacity(0.06) : Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovered = hovering }
        }
    }
}
