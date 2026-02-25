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
        GeometryReader { geometry in
            VStack(spacing: 0) {
                #if !os(macOS)
                relayStatusHeader
                    .padding(.top, 8)
                    .background(Color.platformWindowBackground)
                #endif
                
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
                                .background(Color.platformControlBackground)
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
                            
                            let columns = geometry.size.width < 400 ? [GridItem(.flexible())] : [GridItem(.flexible()), GridItem(.flexible())]
                            
                            LazyVGrid(columns: columns, spacing: 8) {
                                StatsCard(title: "Total Notes", value: "\(statsService.loadedNotesCount)", icon: "doc.text.fill", color: Color.havenPurple, isLoading: statsService.isUpdatingCount && statsService.loadedNotesCount == 0)
                                StatsCard(title: "Storage Used", value: statsService.formattedStorageSize, icon: "internaldrive.fill", color: .blue)
                                StatsCard(title: "Blossom Storage", value: statsService.formattedBlossomSize, icon: "server.rack", color: .green)
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

                            let actionColumns = geometry.size.width < 450 ? [GridItem(.flexible())] : [GridItem(.flexible()), GridItem(.flexible())]
                            
                            LazyVGrid(columns: actionColumns, spacing: 10) {
                                ActionButton(icon: "safari", title: "Open Browser") {
                                    if let url = URL(string: configService.config.webURL) {
                                        #if os(macOS)
                                        NSWorkspace.shared.open(url)
                                        #else
                                        UIApplication.shared.open(url)
                                        #endif
                                    }
                                }

                                ActionButton(icon: "arrow.down.circle", title: "Import Notes", isLoading: relayManager.isImporting) {
                                    relayManager.importNotes(config: configService.config)
                                }
                                .disabled(relayManager.isImporting)

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

                            if relayManager.isImporting {
                                importProgressSection
                            }

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
            }
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
                statsService.refreshStats(relayURLString: urlString)
            }
        }
        .onChange(of: relayManager.importCompleted) { _, completed in
            if completed {
                let urlString = configService.config.relayURL.isEmpty ? "localhost:\(configService.config.relayPort)" : configService.config.relayURL
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    statsService.refreshStats(relayURLString: urlString)
                }
            }
        }
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
                exportStatusMessage = "Export complete"
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
                exportStatusMessage = "Blossom export complete"
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
                        .lineLimit(1)
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
        .background(Color.platformControlBackground)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.havenPurple.opacity(0.2), lineWidth: 1)
        )
        .padding(.horizontal)
    }

    private var relayStatusHeader: some View {
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Relay Status")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)
                    
                    HStack(spacing: 8) {
                        Circle()
                            .fill(relayManager.isBooting ? Color.yellow : (relayManager.isRunning ? Color.green : Color.red))
                            .frame(width: 10, height: 10)
                        
                        Text(relayManager.isBooting ? "Booting..." : (relayManager.isRunning ? "Running" : "Stopped"))
                            .font(.headline)
                            .foregroundColor(.primary)
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
                    Text(relayManager.isRunning ? "Stop" : "Start")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(relayManager.isRunning ? Color.red : Color.havenPurple)
                        .cornerRadius(20)
                }
                .buttonStyle(.plain)
                .disabled(relayManager.isBooting)
            }
            .padding()
            .background(Color.platformControlBackground)
            .cornerRadius(12)
            
            if relayManager.isBooting, !relayManager.bootStatusMessage.isEmpty {
                 Text(relayManager.bootStatusMessage)
                     .font(.caption)
                     .foregroundColor(.secondary)
                     .lineLimit(1)
                     .truncationMode(.middle)
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

    var fullURI: String {
        return uri + endpoint
    }

    var body: some View {
        HStack {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(Color.havenPurple)
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
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.havenPurplePale)
                .cornerRadius(4)

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
        .background(Color.platformControlBackground)
    }
}

struct ActionButton: View {
    let icon: String
    let title: String
    var isLoading: Bool = false
    let action: () -> Void
    
    @Environment(\.controlSize) private var controlSize // Can check size context

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
        .background(isHovered ? color.opacity(0.06) : Color.platformControlBackground)
        .cornerRadius(8)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovered = hovering }
        }
    }
}
