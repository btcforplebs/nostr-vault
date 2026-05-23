import SwiftUI
import UniformTypeIdentifiers

struct DashboardView: View {
    @EnvironmentObject var relayManager: RelayProcessManager
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var statsService: StatsService
    
    @State private var isExporting = false
    @State private var isBackingUpBlossom = false
    @State private var isPreparingImport = false
    @State private var exportStatusMessage = ""
    @State private var relaysExpanded = false
    @State private var statusAnimate = false
    @State private var showingKindBreakdown = false
    @State private var showingBlossomBreakdown = false
    
    var isSidebar: Bool = false
    
    var body: some View {
        GeometryReader { geometry in
            #if os(macOS)
            if geometry.size.width < 750 {
                iOSConsoleLayout(geometry: geometry)
            } else {
                macOSConsoleLayout(geometry: geometry)
            }
            #else
            iOSConsoleLayout(geometry: geometry)
            #endif
        }
        .onAppear {
            // Fresh disk-only refresh on appear
            statsService.refreshStats()

            // If relay is already running AND not booting, get full stats
            if relayManager.isRunning && !relayManager.isBooting {
                let urlString = configService.config.relayURL.isEmpty ? "localhost:\(configService.config.relayPort)" : configService.config.relayURL
                statsService.refreshStats(relayURLString: urlString)
            }
        }
        .onChange(of: relayManager.isBooting) { _, isBooting in
            // When booting finishes, refresh the full stats including remote relay counts
            if !isBooting && relayManager.isRunning {
                let urlString = configService.config.relayURL.isEmpty ? "localhost:\(configService.config.relayPort)" : configService.config.relayURL
                // Delay slightly to ensure WebSocket connections can bind successfully
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    statsService.refreshStats(relayURLString: urlString)
                }
            }
        }
        .onChange(of: relayManager.importCompleted) { _, completed in
            if completed {
                isPreparingImport = false
            }
        }
        .onChange(of: relayManager.isImporting) { _, isImporting in
            if isImporting {
                isPreparingImport = false
            }
        }
        .sheet(isPresented: $showingKindBreakdown) {
            EventKindBreakdownView()
                .environmentObject(statsService)
        }
        .sheet(isPresented: $showingBlossomBreakdown) {
            BlossomBreakdownView()
                .environmentObject(statsService)
                .environmentObject(configService)
        }
    }

    #if os(macOS)
    private func macOSConsoleLayout(geometry: GeometryProxy) -> some View {
        VStack(spacing: 12) {
            relayStatusHeader
                .padding(.top, 8)
                .background(Color(red: 0.08, green: 0.08, blue: 0.1))
            
            // Statistics Grid (Full Width 4 Columns)
            let statsColumns = [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible())
            ]
            
            LazyVGrid(columns: statsColumns, spacing: 12) {
                StatsCard(
                    title: "Total Relay Events",
                    value: "\(statsService.loadedEventsCount)",
                    icon: "doc.text.fill",
                    color: Color.havenPurple,
                    isLoading: statsService.isUpdatingCount && statsService.loadedEventsCount == 0,
                    action: { showingKindBreakdown = true }
                )

                StatsCard(
                    title: "Database Size",
                    value: statsService.formattedStorageSize,
                    icon: "internaldrive.fill",
                    color: .blue
                )
                
                StatsCard(
                    title: "Blossom Storage",
                    value: statsService.formattedBlossomSize,
                    icon: "server.rack",
                    color: .green,
                    action: { showingBlossomBreakdown = true }
                )
                
                StatsCard(
                    title: "Media Cache",
                    value: statsService.formattedCacheSize,
                    icon: "photo.stack.fill",
                    color: .orange
                )
            }
            .padding(.horizontal)
            
            // Side-by-Side Console & Controls
            HStack(alignment: .top, spacing: 16) {
                // Left Column: Relays and Actions
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("LOCAL GATEWAY RELAYS")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(.secondary.opacity(0.8))
                        
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
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.white.opacity(0.04), lineWidth: 0.5)
                        )
                    }
                    
                    if relayManager.isImporting {
                        importProgressSection
                    } else {
                        let actionColumns = [
                            GridItem(.flexible()),
                            GridItem(.flexible())
                        ]
                        
                        LazyVGrid(columns: actionColumns, spacing: 8) {
                            ActionButton(icon: "safari", title: "Browser") {
                                if let url = URL(string: configService.config.webURL) {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            
                            ActionButton(icon: "arrow.down.circle", title: "Import", isLoading: isPreparingImport || relayManager.isImporting) {
                                isPreparingImport = true
                                relayManager.importNotes(config: configService.config)
                            }
                            .disabled(isPreparingImport || relayManager.isImporting)
                            
                            ActionButton(icon: "arrow.up.doc.fill", title: "Export JSONL", isLoading: isExporting) {
                                exportBackup()
                            }
                            .disabled(isExporting || isBackingUpBlossom)
                            
                            ActionButton(icon: "photo.stack", title: "Export Media", isLoading: isBackingUpBlossom) {
                                exportBlossom()
                            }
                            .disabled(isExporting || isBackingUpBlossom)
                        }
                    }
                }
                .frame(width: 380)
                
                // Right Column: System Terminal Logs
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Image(systemName: "terminal.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.green)
                        
                        Text("LOCAL RELAY SERVER CONSOLE")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(.secondary)
                        
                        Spacer()
                        
                        HStack(spacing: 5) {
                            Circle().fill(Color.red.opacity(0.7)).frame(width: 7, height: 7)
                            Circle().fill(Color.yellow.opacity(0.7)).frame(width: 7, height: 7)
                            Circle().fill(Color.green.opacity(0.7)).frame(width: 7, height: 7)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(red: 0.12, green: 0.12, blue: 0.15))
                    
                    Divider()
                        .background(Color.white.opacity(0.06))
                    
                    LogsView(logStore: relayManager.logStore, hideHeader: true)
                        .frame(maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(red: 0.05, green: 0.05, blue: 0.07))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.green.opacity(0.12), lineWidth: 1)
                )
            }
            .padding(.horizontal)
            .padding(.bottom, 12)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(red: 0.08, green: 0.08, blue: 0.1).ignoresSafeArea())
    }
    #endif

    private func iOSConsoleLayout(geometry: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            if isSidebar {
                #if os(macOS)
                HStack(spacing: 8) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.havenPurple)
                    Text("Relay Dashboard")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.primary)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.top, 14)
                .padding(.bottom, 6)
                .background(Color(red: 0.08, green: 0.08, blue: 0.1))
                #endif
            }
            
            relayStatusHeader
                .padding(.top, isSidebar ? 4 : 8)
                .background(Color(red: 0.08, green: 0.08, blue: 0.1))
            
            ScrollView {
                VStack(spacing: 20) {
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
                            .background(Color.platformSeparator)
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.platformSeparator, lineWidth: 0.5)
                            )
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
                        
                        let columns = geometry.size.width < 400 ? [GridItem(.flexible())] : [GridItem(.flexible()), GridItem(.flexible())]
                        
                        LazyVGrid(columns: columns, spacing: 8) {
                            StatsCard(title: "Total Relay Events", value: "\(statsService.loadedEventsCount)", icon: "doc.text.fill", color: Color.havenPurple, isLoading: statsService.isUpdatingCount && statsService.loadedEventsCount == 0, action: { showingKindBreakdown = true })
                            StatsCard(title: "Storage Used", value: statsService.formattedStorageSize, icon: "internaldrive.fill", color: .blue)
                            StatsCard(title: "Blossom Storage", value: statsService.formattedBlossomSize, icon: "server.rack", color: .green, action: { showingBlossomBreakdown = true })
                            StatsCard(title: "Media Cache", value: statsService.formattedCacheSize, icon: "photo.stack.fill", color: .orange)
                        }
                        .padding(.horizontal)
                    }
                    
                    // MARK: - Actions
                    Spacer(minLength: 8)
                    
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Actions")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.secondary)
                            .padding(.horizontal)

                        if relayManager.isImporting {
                            importProgressSection
                        }
                        
                        let actionColumns = geometry.size.width < 450 ? [GridItem(.flexible())] : [GridItem(.flexible()), GridItem(.flexible())]

                        LazyVGrid(columns: actionColumns, spacing: 10) {
                            #if os(macOS)
                            ActionButton(icon: "safari", title: "Open Browser") {
                                if let url = URL(string: configService.config.webURL) {
                                    #if os(macOS)
                                    NSWorkspace.shared.open(url)
                                    #else
                                    UIApplication.shared.open(url)
                                    #endif
                                }
                            }
                            #endif

                            ActionButton(icon: "arrow.down.circle", title: "Import Notes", isLoading: isPreparingImport || relayManager.isImporting) {
                                isPreparingImport = true
                                relayManager.importNotes(config: configService.config)
                            }
                            .disabled(isPreparingImport || relayManager.isImporting)

                            ActionButton(icon: "arrow.up.doc.fill", title: "Export JSONL", isLoading: isExporting) {
                                exportBackup()
                            }
                            .disabled(isExporting || isBackingUpBlossom)

                            ActionButton(icon: "photo.stack", title: "Export Blossom", isLoading: isBackingUpBlossom) {
                                exportBlossom()
                            }
                            .disabled(isExporting || isBackingUpBlossom)
                        }
                        .padding(.horizontal)

                        if !exportStatusMessage.isEmpty {
                            Text(exportStatusMessage)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.horizontal)
                        }
                    }
                    .disabled(!relayManager.isRunning && !relayManager.isImporting)
                    .padding(.horizontal)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .frame(minHeight: 350, maxHeight: .infinity, alignment: .top)
            }
            .refreshable {
                guard relayManager.isRunning && !relayManager.isImporting else { return }
                isPreparingImport = true
                relayManager.importNotes(config: configService.config)

                while relayManager.isImporting {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                isPreparingImport = false
            }
        }
        .background(Color(red: 0.08, green: 0.08, blue: 0.1).ignoresSafeArea())
    }
    
    private func geometryHeight(for width: CGFloat) -> CGFloat {
        var height: CGFloat = 350
        if relaysExpanded { height += 250 }
        if width < 400 { height += 200 } // Stacked stats
        if width < 350 { height += 150 } // Stacked buttons
        return height
    }
    
    private func exportBackup() {
        isExporting = true
        exportStatusMessage = "Preparing export..."

        let tempDir = NSTemporaryDirectory()
        let tempPath = (tempDir as NSString).appendingPathComponent("haven-backup-\(Date().timeIntervalSince1970).zip")

        relayManager.runBackupExport(config: configService.config, outputPath: tempPath) { success in
            Task { @MainActor in
                isExporting = false

                guard success else {
                    exportStatusMessage = "Export failed"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        exportStatusMessage = ""
                    }
                    return
                }

                #if os(macOS)
                let panel = NSSavePanel()
                panel.title = "Save JSONL Backup"
                panel.nameFieldStringValue = "haven-backup.zip"
                panel.allowedContentTypes = [.zip]
                panel.canCreateDirectories = true
                
                if panel.runModal() == .OK, let destURL = panel.url {
                    let srcURL = URL(fileURLWithPath: tempPath)
                    do {
                        if FileManager.default.fileExists(atPath: destURL.path) {
                            try FileManager.default.removeItem(at: destURL)
                        }
                        try FileManager.default.moveItem(at: srcURL, to: destURL)
                        exportStatusMessage = "Saved to \(destURL.lastPathComponent)"
                    } catch {
                        exportStatusMessage = "Failed to save: \(error.localizedDescription)"
                    }
                } else {
                    // User cancelled the save panel
                    exportStatusMessage = "Export cancelled"
                    try? FileManager.default.removeItem(atPath: tempPath)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    exportStatusMessage = ""
                }
                #else
                // iOS: Share the file
                let fileURL = URL(fileURLWithPath: tempPath)
                let activityVC = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)

                if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let window = scene.windows.first,
                   let rootVC = window.rootViewController {
                    rootVC.present(activityVC, animated: true)
                }
                #endif
            }
        }
    }
    
    private func exportBlossom() {
        isBackingUpBlossom = true
        exportStatusMessage = "Preparing Blossom export..."

        let tempDir = NSTemporaryDirectory()
        let tempPath = (tempDir as NSString).appendingPathComponent("blossom-backup-\(Date().timeIntervalSince1970).zip")

        relayManager.runBlossomExportWithExtensions(config: configService.config, outputPath: tempPath) { success in
            Task { @MainActor in
                isBackingUpBlossom = false

                guard success else {
                    exportStatusMessage = "Blossom export failed"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        exportStatusMessage = ""
                    }
                    return
                }

                #if os(macOS)
                let panel = NSSavePanel()
                panel.title = "Save Blossom Backup"
                panel.nameFieldStringValue = "blossom-backup.zip"
                panel.allowedContentTypes = [.zip]
                panel.canCreateDirectories = true
                
                if panel.runModal() == .OK, let destURL = panel.url {
                    let srcURL = URL(fileURLWithPath: tempPath)
                    do {
                        if FileManager.default.fileExists(atPath: destURL.path) {
                            try FileManager.default.removeItem(at: destURL)
                        }
                        try FileManager.default.moveItem(at: srcURL, to: destURL)
                        exportStatusMessage = "Saved to \(destURL.lastPathComponent)"
                    } catch {
                        exportStatusMessage = "Failed to save: \(error.localizedDescription)"
                    }
                } else {
                    exportStatusMessage = "Export cancelled"
                    try? FileManager.default.removeItem(atPath: tempPath)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    exportStatusMessage = ""
                }
                #else
                // iOS: Share the file
                let fileURL = URL(fileURLWithPath: tempPath)
                let activityVC = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)

                if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let window = scene.windows.first,
                   let rootVC = window.rootViewController {
                    rootVC.present(activityVC, animated: true)
                }
                #endif
            }
        }
    }

    private var importProgressSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Import Progress")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)
                    
                    Text(relayManager.importStatusMessage)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                
                Spacer()
                
                Text("\(Int(relayManager.importProgress * 100))%")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(Color.havenPurple)
            }
            
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.havenPurple.opacity(0.1))
                    
                    RoundedRectangle(cornerRadius: 6)
                        .fill(
                            LinearGradient(
                                gradient: Gradient(colors: [.havenPurple, .havenPurpleLight]),
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: geo.size.width * relayManager.importProgress)
                }
            }
            .frame(height: 8)
            
            if relayManager.importProgress >= 1.0 || relayManager.importStatusMessage.contains("Complete") {
                Button(action: {
                    relayManager.dismissImport()
                }) {
                    Text("Dismiss")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.havenPurple)
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
        .padding()
        .background(Color.platformSecondaryGroupedBackground)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.havenPurple.opacity(0.2), lineWidth: 1)
        )
        .padding(.horizontal)
    }

    private var relayStatusHeader: some View {
        let statusColor = relayManager.isBooting ? Color.yellow : (relayManager.isRunning ? Color.green : Color.red)
        return VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("RELAY STATUS")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.secondary.opacity(0.8))

                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(statusColor.opacity(0.15))
                                .frame(width: 24, height: 24)
                                .scaleEffect(statusAnimate ? 1.3 : 1.0)

                            Circle()
                                .stroke(statusColor.opacity(0.5), lineWidth: 1.5)
                                .frame(width: 18, height: 18)
                                .scaleEffect(statusAnimate ? 1.5 : 1.0)
                                .opacity(statusAnimate ? 0.0 : 1.0)

                            Circle()
                                .fill(statusColor)
                                .frame(width: 10, height: 10)
                                .shadow(color: statusColor.opacity(0.8), radius: 4)
                        }

                        Text(relayManager.isBooting ? "BOOTING..." : (relayManager.isRunning ? "ONLINE" : "OFFLINE"))
                             .font(.system(size: 16, weight: .bold, design: .monospaced))
                             .foregroundColor(.white)
                    }
                }

                Spacer()

                Button(action: {
                    if relayManager.isRunning {
                        relayManager.stopRelay()
                    } else {
                        relayManager.startRelay(config: configService.config)
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: relayManager.isRunning ? "stop.fill" : "play.fill")
                            .font(.system(size: 11, weight: .bold))
                        Text(relayManager.isRunning ? "Stop Relay" : "Start Relay")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        LinearGradient(
                            gradient: Gradient(colors: relayManager.isRunning
                                ? [Color.red.opacity(0.8), Color.red.opacity(0.6)]
                                : [Color.havenPurple, Color.havenPurpleDark]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .cornerRadius(8)
                    .shadow(color: (relayManager.isRunning ? Color.red : Color.havenPurple).opacity(0.3), radius: 6, x: 0, y: 3)
                }
                .buttonStyle(.plain)
                .disabled(relayManager.isBooting)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(red: 0.1, green: 0.1, blue: 0.12).opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        LinearGradient(
                            gradient: Gradient(colors: [
                                statusColor.opacity(0.35),
                                Color.white.opacity(0.06),
                                Color.white.opacity(0.02)
                            ]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: statusColor.opacity(relayManager.isRunning && !relayManager.isBooting ? 0.08 : 0), radius: 10, x: 0, y: 4)
            
            if relayManager.isBooting, !relayManager.bootStatusMessage.isEmpty {
                 Text(relayManager.bootStatusMessage)
                      .font(.system(size: 11, design: .monospaced))
                      .foregroundColor(.yellow.opacity(0.8))
                      .lineLimit(2)
                      .fixedSize(horizontal: false, vertical: true)
            }

            // Error recovery banner
            if relayManager.isLocked || relayManager.isPortConflict {
                VStack(spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text(relayManager.isPortConflict ? "Port 3355 is already in use" : "Database lock detected")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.primary)
                        Spacer()
                    }

                    Text(relayManager.isPortConflict
                        ? "Another process is using the relay port. Close other Nostr Vault instances or restart your computer."
                        : "A previous session did not shut down cleanly. Clear locks to restart the relay.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 12) {
                        Button {
                            relayManager.forceCleanAndRestart()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.clockwise")
                                Text("Force Restart")
                            }
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.havenPurple)
                            .cornerRadius(8)
                        }
                        .buttonStyle(.plain)

                        if relayManager.isLocked {
                            Button {
                                relayManager.clearDatabaseLocks { [relayManager, configService] in
                                    Task { @MainActor in
                                        relayManager.startRelay(config: configService.config, isRetry: true)
                                    }
                                }
                            } label: {
                                Text("Clear Locks Only")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding()
                .background(Color.orange.opacity(0.08))
                .cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.3), lineWidth: 1))
            }
        }
        .padding(.horizontal)
    }
}


struct RelayRow: View {
    let name: String
    let subtitle: String
    let icon: String
    let uri: String
    let endpoint: String

    @State private var copied = false
    @State private var isHovered = false

    var fullURI: String {
        return uri + endpoint
    }

    var body: some View {
        HStack {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Color.havenPurple)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Spacer()

            Text(fullURI)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(copied ? .green : Color.havenPurpleLight)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.black.opacity(copied ? 0.5 : 0.35))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(copied ? Color.green.opacity(0.6) : Color.havenPurple.opacity(0.3), lineWidth: 1)
                )
                .scaleEffect(copied ? 1.05 : 1.0)
                .animation(.spring(response: 0.25, dampingFraction: 0.65), value: copied)

            Button(action: {
                #if os(macOS)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(fullURI, forType: .string)
                #else
                UIPasteboard.general.string = fullURI
                #endif
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
        .background(isHovered ? Color(red: 0.14, green: 0.14, blue: 0.14).opacity(0.75) : Color(red: 0.12, green: 0.12, blue: 0.12).opacity(0.6))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isHovered ? Color.havenPurple.opacity(0.2) : Color.white.opacity(0.03), lineWidth: 0.5)
        )
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

struct ActionButton: View {
    let icon: String
    let title: String
    var isLoading: Bool = false
    let action: () -> Void
    
    @Environment(\.controlSize) private var controlSize // Can check size context
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .colorScheme(.dark)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(.white)
                }
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                LinearGradient(
                    gradient: Gradient(colors: [Color.havenPurple, Color.havenPurpleDark]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
            )
            .scaleEffect(isHovered ? 1.03 : 1.0)
            .shadow(color: Color.havenPurple.opacity(isHovered ? 0.35 : 0.0), radius: 8, x: 0, y: 4)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

struct StatsCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    var isLoading: Bool = false
    var action: (() -> Void)? = nil

    @State private var isHovered = false

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(color)
                    .font(.system(size: 16))
                Spacer()
                if action != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary.opacity(0.6))
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.8, anchor: .leading)
                        .frame(height: 24)
                } else {
                    Text(value)
                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                }
                Text(title)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(isHovered ? color.opacity(0.08) : Color(red: 0.12, green: 0.12, blue: 0.12).opacity(0.5))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isHovered ? color.opacity(0.4) : Color.white.opacity(0.06), lineWidth: 1.0)
        )
        .shadow(color: color.opacity(isHovered ? 0.18 : 0.0), radius: 8, x: 0, y: 3)
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isHovered)
    }

    var body: some View {
        Group {
            if let action = action {
                Button(action: action) { content }
                    .buttonStyle(.plain)
            } else {
                content
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovered = hovering && action != nil }
        }
    }
}

struct EventKindBreakdownView: View {
    @EnvironmentObject var statsService: StatsService
    @Environment(\.dismiss) private var dismiss

    @State private var counts: [Int: Int] = [:]
    @State private var isLoading = true

    private static let kindNames: [Int: String] = [
        0: "Profile Metadata",
        1: "Short Notes",
        3: "Contacts",
        4: "Encrypted DMs (legacy)",
        5: "Event Deletions",
        6: "Reposts",
        7: "Reactions",
        8: "Badge Awards",
        9: "Chat Messages",
        16: "Generic Reposts",
        1059: "Gift Wraps (DMs)",
        1063: "File Metadata",
        1311: "Live Chat",
        1808: "Audio Tracks",
        9734: "Zap Requests",
        9735: "Zap Receipts",
        10000: "Mute Lists",
        10001: "Pinned Notes",
        10002: "Relay Lists",
        10003: "Bookmarks",
        10005: "Public Chats",
        10006: "Blocked Relays",
        10015: "Interest Lists",
        10030: "Emoji Lists",
        30000: "People Lists",
        30001: "Generic Lists",
        30002: "Relay Sets",
        30008: "Profile Badges",
        30009: "Badge Definitions",
        30023: "Long-form Articles",
        30024: "Long-form Drafts",
        30030: "Emoji Sets",
        30078: "App Data"
    ]

    private var total: Int { counts[-1] ?? 0 }

    private var sortedKinds: [(kind: Int, count: Int)] {
        counts.filter { $0.key != -1 }
              .sorted { $0.value > $1.value }
              .map { (kind: $0.key, count: $0.value) }
    }

    private var knownTotal: Int {
        sortedKinds.reduce(0) { $0 + $1.count }
    }

    private var otherCount: Int {
        max(0, total - knownTotal)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.08, green: 0.08, blue: 0.1).ignoresSafeArea()

                if isLoading {
                    VStack(spacing: 16) {
                        ProgressView()
                            .controlSize(.large)
                            .tint(Color.havenPurple)
                        Text("Counting events by kind…")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 8) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("\(total)")
                                        .font(.system(size: 28, weight: .bold, design: .monospaced))
                                        .foregroundColor(.white)
                                    Text("Total Events")
                                        .font(.system(size: 12))
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                            }
                            .padding(16)
                            .background(Color.havenPurple.opacity(0.1))
                            .cornerRadius(12)
                            .padding(.horizontal)
                            .padding(.top, 12)

                            VStack(spacing: 1) {
                                ForEach(sortedKinds, id: \.kind) { item in
                                    KindRow(
                                        kind: item.kind,
                                        name: Self.kindNames[item.kind] ?? "Kind \(item.kind)",
                                        count: item.count,
                                        total: total
                                    )
                                }

                                if otherCount > 0 {
                                    KindRow(
                                        kind: -2,
                                        name: "Other (unqueried kinds)",
                                        count: otherCount,
                                        total: total
                                    )
                                }
                            }
                            .padding(.horizontal)
                            .padding(.bottom, 24)
                        }
                    }
                }
            }
            .navigationTitle("Event Breakdown")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { Task { await reload() } }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 560, idealHeight: 640)
        #endif
        .task { await reload() }
    }

    private func reload() async {
        isLoading = true
        counts = await statsService.fetchCountsByKind()
        isLoading = false
    }
}

struct BlossomBreakdownView: View {
    @EnvironmentObject var statsService: StatsService
    @EnvironmentObject var configService: ConfigService
    @Environment(\.dismiss) private var dismiss

    @State private var blobs: [BlobDescriptor] = []
    @State private var isLoading = true

    private var totalCount: Int { blobs.count }
    private var totalSize: Int { blobs.compactMap(\.size).reduce(0, +) }

    private struct TypeBucket {
        let label: String
        let icon: String
        let color: Color
        let count: Int
        let size: Int
    }

    private var buckets: [TypeBucket] {
        var images = (count: 0, size: 0), videos = (count: 0, size: 0), audio = (count: 0, size: 0), other = (count: 0, size: 0)
        for blob in blobs {
            let t = blob.type ?? ""
            let s = blob.size ?? 0
            if t.hasPrefix("image/") { images.count += 1; images.size += s }
            else if t.hasPrefix("video/") { videos.count += 1; videos.size += s }
            else if t.hasPrefix("audio/") { audio.count += 1; audio.size += s }
            else { other.count += 1; other.size += s }
        }
        return [
            TypeBucket(label: "Images", icon: "photo.fill", color: .blue, count: images.count, size: images.size),
            TypeBucket(label: "Videos", icon: "video.fill", color: .orange, count: videos.count, size: videos.size),
            TypeBucket(label: "Audio", icon: "waveform", color: .purple, count: audio.count, size: audio.size),
            TypeBucket(label: "Other", icon: "doc.fill", color: .secondary, count: other.count, size: other.size),
        ].filter { $0.count > 0 }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.08, green: 0.08, blue: 0.1).ignoresSafeArea()

                if isLoading {
                    VStack(spacing: 16) {
                        ProgressView()
                            .controlSize(.large)
                            .tint(Color.havenPurple)
                        Text("Counting blobs…")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 8) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("\(totalCount)")
                                        .font(.system(size: 28, weight: .bold, design: .monospaced))
                                        .foregroundColor(.white)
                                    Text("Total Blobs")
                                        .font(.system(size: 12))
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 4) {
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(totalSize), countStyle: .file))
                                        .font(.system(size: 28, weight: .bold, design: .monospaced))
                                        .foregroundColor(.white)
                                    Text("Total Size")
                                        .font(.system(size: 12))
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(16)
                            .background(Color.havenPurple.opacity(0.1))
                            .cornerRadius(12)
                            .padding(.horizontal)
                            .padding(.top, 12)

                            VStack(spacing: 1) {
                                ForEach(buckets, id: \.label) { bucket in
                                    BlobTypeRow(
                                        label: bucket.label,
                                        icon: bucket.icon,
                                        color: bucket.color,
                                        count: bucket.count,
                                        size: bucket.size,
                                        total: totalSize
                                    )
                                }
                            }
                            .padding(.horizontal)
                            .padding(.bottom, 24)
                        }
                    }
                }
            }
            .navigationTitle("Blob Breakdown")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { Task { await reload() } }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 560, idealHeight: 640)
        #endif
        .task { await reload() }
    }

    private func reload() async {
        isLoading = true
        let pubkey = configService.activeAccountHexPubkey
        blobs = await statsService.fetchBlobList(for: pubkey)
        isLoading = false
    }
}

private struct BlobTypeRow: View {
    let label: String
    let icon: String
    let color: Color
    let count: Int
    let size: Int
    let total: Int

    private var sizePercent: Double {
        guard total > 0 else { return 0 }
        return Double(size) / Double(total)
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(color)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                Text("\(count) \(count == 1 ? "blob" : "blobs")")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundColor(color)
                Text(String(format: "%.1f%%", sizePercent * 100))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(red: 0.12, green: 0.12, blue: 0.12).opacity(0.6))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.04), lineWidth: 0.5)
        )
        .cornerRadius(8)
    }
}

private struct KindRow: View {
    let kind: Int
    let name: String
    let count: Int
    let total: Int

    private var percent: Double {
        guard total > 0 else { return 0 }
        return Double(count) / Double(total)
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                Text(kind >= 0 ? "kind \(kind)" : "—")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(count)")
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .foregroundColor(Color.havenPurple)
                Text(String(format: "%.1f%%", percent * 100))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(red: 0.12, green: 0.12, blue: 0.12).opacity(0.6))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.04), lineWidth: 0.5)
        )
        .cornerRadius(8)
    }
}
