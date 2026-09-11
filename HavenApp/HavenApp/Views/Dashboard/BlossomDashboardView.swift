import SwiftUI

// MARK: - BlossomDashboardView

/// Fast-loading Blossom dashboard with stats, mirror management, and media grid.
/// All operations are inline with no blocking popups.
struct BlossomDashboardView: View {
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var nostrService: NostrService
    @Environment(\.dismiss) private var dismiss

    @State private var stats = BlossomStats()
    @State private var mirrors: [MirrorInfo] = []
    @State private var isLoadingStats = true
    @State private var showMirrorSection = false
    @State private var showingBlossomSettings = false

    // Sync operations
    @State private var isPulling = false
    @State private var isPushing = false
    @State private var syncProgress: Double = 0
    @State private var syncMessage: String = ""

    // Activity logs
    @State private var activityLogs: [BlossomActivityLog] = []

    var body: some View {
        // NavigationStack, not the deprecated NavigationView: on macOS the latter
        // resolves to a split view, so the dashboard opened as an empty sidebar with
        // its content pushed into a detail pane it never fills.
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Stats Section
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader(title: "STATISTICS")
                        StatsSection(stats: stats, isLoading: isLoadingStats)
                    }
                    .padding(.horizontal)

                    // Quick Actions
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader(title: "QUICK ACTIONS")
                        QuickActionsSection(
                            stats: stats,
                            isPulling: $isPulling,
                            isPushing: $isPushing,
                            syncProgress: syncProgress,
                            syncMessage: syncMessage,
                            onPull: pullFromNotes,
                            onPush: pushAllToMirrors,
                            onRefresh: refreshAll
                        )
                    }
                    .padding(.horizontal)

                    // Mirror Status (Expandable)
                    if !mirrors.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionHeader(title: "MIRRORS")
                            MirrorStatusSection(
                                mirrors: mirrors,
                                isExpanded: $showMirrorSection,
                                onTest: testMirrors
                            )
                        }
                        .padding(.horizontal)
                    }

                    Divider()
                        .padding(.vertical, 8)

                    // Storage Breakdown
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader(title: "STORAGE OVERVIEW")
                        StorageBreakdownSection(stats: stats)
                    }
                    .padding(.horizontal)

                    Divider()
                        .padding(.vertical, 8)

                    // Activity Console
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader(title: "ACTIVITY LOG")

                        VStack(alignment: .leading, spacing: 0) {
                            HStack {
                                Image(systemName: "terminal.fill")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.havenPurple)

                                Text("CONSOLE")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundColor(.secondary.opacity(0.8))

                                Spacer()

                                HStack(spacing: 5) {
                                    Circle().fill(Color.red.opacity(0.7)).frame(width: 7, height: 7)
                                    Circle().fill(Color.yellow.opacity(0.7)).frame(width: 7, height: 7)
                                    Circle().fill(Color.green.opacity(0.7)).frame(width: 7, height: 7)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.platformSecondaryGroupedBackground)

                            Divider()

                            ActivityLogView(logs: activityLogs, syncMessage: syncMessage)
                                .frame(height: 300)
                        }
                        .background(Color.platformTertiaryGroupedBackground)
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.havenPurple.opacity(0.12), lineWidth: 1)
                        )
                    }
                    .padding(.horizontal)
                }
                .padding(.vertical)
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        Image(systemName: "camera.macro")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.havenPurple)
                        Text("Blossom")
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 12) {
                        Button(action: { showingBlossomSettings = true }) {
                            Image(systemName: "gearshape")
                        }

                        Button(action: refreshAll) {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(isLoadingStats || isPulling || isPushing)
                    }
                }
            }
        }
        .task {
            await loadDashboard()
        }
        .sheet(isPresented: $showingBlossomSettings) {
            NavigationStack {
                BlossomSettingsView()
                    .environmentObject(configService)
                    .environmentObject(nostrService)
                    #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    #endif
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showingBlossomSettings = false }
                                .foregroundColor(.havenPurple)
                        }
                    }
            }
        }
    }

    private func loadDashboard() async {
        await loadStats()
        await loadMirrors()
        addLog("Dashboard loaded", level: .info)
    }

    private func loadStats() async {
        isLoadingStats = true

        let relayDataDir = await MainActor.run { configService.relayDataDir }
        let blossomPath = await MainActor.run { configService.config.blossomPath }
        let blossomDir = relayDataDir.appendingPathComponent(blossomPath)

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: blossomDir,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            await MainActor.run { isLoadingStats = false }
            return
        }

        let validFiles = files.filter { url in
            let hashPart = url.deletingPathExtension().lastPathComponent
            return hashPart.count == 64 && hashPart.allSatisfy { $0.isHexDigit }
        }

        let totalSize = validFiles.reduce(0) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return total + size
        }

        await MainActor.run {
            stats.totalFiles = validFiles.count
            stats.totalSize = Int64(totalSize)
            isLoadingStats = false
        }
    }

    private func loadMirrors() async {
        let mirrorURLs = await MainActor.run { configService.config.activeBlossomMirrors }

        let mirrorInfos = mirrorURLs.map { urlString in
            MirrorInfo(
                id: UUID(),
                url: urlString,
                host: URL(string: urlString)?.host ?? urlString,
                isHealthy: nil,
                responseTime: nil,
                fileCount: nil
            )
        }

        await MainActor.run {
            mirrors = mirrorInfos
            stats.mirrorCount = mirrorInfos.count
        }

        // Auto-check health after loading
        await checkMirrorHealth()
    }

    private func checkMirrorHealth() async {
        let currentMirrors = await MainActor.run { mirrors }
        guard !currentMirrors.isEmpty else { return }

        await withTaskGroup(of: (Int, Bool, Int?).self) { group in
            for (index, mirror) in currentMirrors.enumerated() {
                group.addTask {
                    let start = Date()
                    guard let url = URL(string: mirror.url) else {
                        return (index, false, nil)
                    }
                    var request = URLRequest(url: url)
                    request.httpMethod = "HEAD"
                    request.timeoutInterval = 10
                    do {
                        let (_, response) = try await URLSession.shared.data(for: request)
                        let elapsed = Int(Date().timeIntervalSince(start) * 1000)
                        if let httpResponse = response as? HTTPURLResponse,
                           (200..<500).contains(httpResponse.statusCode) {
                            return (index, true, elapsed)
                        }
                        return (index, false, elapsed)
                    } catch {
                        return (index, false, nil)
                    }
                }
            }

            for await (index, healthy, responseTime) in group {
                await MainActor.run {
                    guard index < mirrors.count else { return }
                    mirrors[index].isHealthy = healthy
                    mirrors[index].responseTime = responseTime
                }
            }
        }

        let healthyCount = await MainActor.run { mirrors.filter { $0.isHealthy == true }.count }
        let totalCount = await MainActor.run { mirrors.count }
        addLog("Mirror check: \(healthyCount)/\(totalCount) healthy", level: healthyCount == totalCount ? .success : .warning)
    }

    private func addLog(_ message: String, level: BlossomActivityLog.LogLevel) {
        let log = BlossomActivityLog(timestamp: Date(), message: message, level: level)
        activityLogs.insert(log, at: 0)
        // Keep only last 50 logs
        if activityLogs.count > 50 {
            activityLogs = Array(activityLogs.prefix(50))
        }
    }

    private func refreshAll() {
        Task {
            await loadDashboard()
        }
    }

    private func pullFromNotes() {
        Task {
            await MainActor.run {
                isPulling = true
                syncProgress = 0
                syncMessage = "Scanning notes for media..."
                addLog("Started pulling media from notes", level: .info)
            }

            let service = BlossomService(configService: configService, nostrService: nostrService)
            let noteMedia = await MainActor.run { nostrService.noteMedia }

            var pulledCount = 0
            _ = await service.mirrorFromNoteMedia(noteMedia) { current, total in
                Task { @MainActor in
                    syncProgress = total > 0 ? Double(current) / Double(total) : 0
                    syncMessage = "Pulled \(current) of \(total) files"
                    pulledCount = current
                }
            }

            await loadDashboard()

            await MainActor.run {
                isPulling = false
                syncMessage = ""
                addLog("Completed pulling \(pulledCount) files from notes", level: .success)
            }
        }
    }

    private func pushAllToMirrors() {
        Task {
            let mirrorURLs = await MainActor.run { configService.config.activeBlossomMirrors }
            guard !mirrorURLs.isEmpty else {
                await MainActor.run { addLog("No mirrors configured — add one in Blossom Settings", level: .warning) }
                return
            }

            let hashes = await localBlossomFileHashes()
            guard !hashes.isEmpty else {
                await MainActor.run { addLog("No local files to back up", level: .info) }
                return
            }

            await MainActor.run {
                isPushing = true
                syncProgress = 0
                syncMessage = "Checking mirror status..."
                addLog("Checking \(hashes.count) file\(hashes.count == 1 ? "" : "s") against \(mirrorURLs.count) mirror\(mirrorURLs.count == 1 ? "" : "s")...", level: .info)
            }

            let service = BlossomService(configService: configService, nostrService: nostrService)

            // Only push blobs missing from at least one configured mirror — a HEAD
            // check is far cheaper than re-uploading blobs that are already there.
            // The checking phase gets the first half of the progress bar so it
            // doesn't sit at 0% while potentially scanning many files.
            var needsPush: [String] = []
            for (index, hash) in hashes.enumerated() {
                let status = await service.checkMirrorStatus(sha256: hash)
                if mirrorURLs.contains(where: { status[$0] != true }) {
                    needsPush.append(hash)
                }
                await MainActor.run {
                    syncProgress = 0.5 * Double(index + 1) / Double(hashes.count)
                }
            }

            guard !needsPush.isEmpty else {
                await MainActor.run {
                    isPushing = false
                    syncMessage = ""
                    stats.backedUpCount = hashes.count
                    addLog("All files already backed up", level: .success)
                }
                return
            }

            await MainActor.run {
                syncMessage = "Backing up \(needsPush.count) file\(needsPush.count == 1 ? "" : "s")..."
                addLog("Pushing \(needsPush.count) file\(needsPush.count == 1 ? "" : "s") to mirrors", level: .info)
            }

            var succeeded = 0
            var failed = 0
            for (index, hash) in needsPush.enumerated() {
                let ok = await service.pushLocalToMirrors(sha256: hash)
                if ok { succeeded += 1 } else { failed += 1 }
                await MainActor.run {
                    syncProgress = 0.5 + 0.5 * Double(index + 1) / Double(needsPush.count)
                    syncMessage = "Backed up \(index + 1) of \(needsPush.count)..."
                }
            }

            await MainActor.run {
                isPushing = false
                syncMessage = ""
                stats.backedUpCount = hashes.count - failed
                if failed == 0 {
                    addLog("Completed backup — \(succeeded) file\(succeeded == 1 ? "" : "s") pushed to mirrors", level: .success)
                } else {
                    addLog("Backup finished with \(failed) failure\(failed == 1 ? "" : "s") (\(succeeded) succeeded)", level: .warning)
                }
            }
        }
    }

    /// Local Blossom blob hashes (filename minus extension) — same hex-sha256
    /// filter loadStats() uses to recognize a real blob vs stray file.
    private func localBlossomFileHashes() async -> [String] {
        let relayDataDir = await MainActor.run { configService.relayDataDir }
        let blossomPath = await MainActor.run { configService.config.blossomPath }
        let blossomDir = relayDataDir.appendingPathComponent(blossomPath)

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: blossomDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return files.compactMap { url in
            let hash = url.deletingPathExtension().lastPathComponent
            return (hash.count == 64 && hash.allSatisfy { $0.isHexDigit }) ? hash : nil
        }
    }

    private func testMirrors() {
        Task {
            addLog("Testing mirror connectivity...", level: .info)
            // Reset to pending state
            await MainActor.run {
                for i in mirrors.indices {
                    mirrors[i].isHealthy = nil
                    mirrors[i].responseTime = nil
                }
            }
            await checkMirrorHealth()
        }
    }
}
