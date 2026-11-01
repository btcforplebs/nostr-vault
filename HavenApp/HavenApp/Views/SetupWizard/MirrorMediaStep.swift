import SwiftUI
import UniformTypeIdentifiers

// MARK: - Step 5: Mirror Media

struct MirrorMediaStep: View {
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var nostrService: NostrService
    let onContinue: () -> Void
    let onSkip: () -> Void

    @State private var appeared = false
    @State private var activeTab = 0
    @State private var blossomURL = "https://blossom.primal.net"
    /// The field still holds the suggestion: the owner's own first server
    /// replaces it once their list (kind 10063) is found.
    @State private var blossomURLEdited = false
    @State private var showingFileImporter = false
    @State private var isSyncing = false
    @State private var syncCompleted = false
    @State private var syncError: String?
    @State private var showSyncError = false
    @State private var progressMessage = ""
    @State private var progressValue: Double = 0
    @State private var syncedCount = 0
    @State private var totalCount = 0

    var body: some View {
        VStack(spacing: 24) {
            Spacer().frame(height: 20)

            Text(String(localized: "setup.media.title"))
                .font(.appSystem(size: isIOSDevice ? 24 : 28, weight: .semibold))
                .foregroundColor(WizardColors.textPrimary)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 10)
                .animation(WizardAnimations.springEnter.delay(0.1), value: appeared)

            Text(String(localized: "setup.media.subtitle"))
                .font(.appSystem(size: 15))
                .foregroundColor(WizardColors.textSecondary)
                .multilineTextAlignment(.center)
                .opacity(appeared ? 1 : 0)
                .animation(WizardAnimations.fadeIn.delay(0.2), value: appeared)

            // Tab bar
            HStack(spacing: 4) {
                tabPill(String(localized: "setup.media.tab.server"), isActive: activeTab == 0) { activeTab = 0 }
                tabPill(String(localized: "setup.media.tab.backup"), isActive: activeTab == 1) { activeTab = 1 }
            }
            .padding(3)
            .background(WizardColors.bgCard)
            .cornerRadius(10)
            .opacity(appeared ? 1 : 0)
            .animation(WizardAnimations.fadeIn.delay(0.25), value: appeared)

            Group {
                if activeTab == 0 {
                    serverSyncContent
                } else {
                    backupImportContent
                }
            }
            .opacity(appeared ? 1 : 0)
            .animation(WizardAnimations.fadeIn.delay(0.3), value: appeared)

            WizardSkipLink(title: String(localized: "setup.media.skip")) { onSkip() }

            Spacer().frame(height: 8)
        }
        .onAppear { appeared = true }
        .task { await prefillFromTheirList() }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.zip],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                importMedia(from: url)
            case .failure(let error):
                syncError = error.localizedDescription
                showSyncError = true
            }
        }
        .alert(String(localized: "setup.media.alert.importFailed"), isPresented: $showSyncError) {
            Button(String(localized: "setup.alert.ok"), role: .cancel) {}
        } message: {
            Text(syncError ?? "Unknown error")
        }
    }

    @ViewBuilder
    private var serverSyncContent: some View {
        VStack(spacing: 14) {
            if isSyncing {
                VStack(spacing: 16) {
                    // Circular progress
                    ZStack {
                        Circle()
                            .stroke(WizardColors.bgElevated, lineWidth: 6)
                            .frame(width: 80, height: 80)
                        Circle()
                            .trim(from: 0, to: progressValue)
                            .stroke(WizardColors.accentGradient, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                            .frame(width: 80, height: 80)
                            .rotationEffect(.degrees(-90))
                            .animation(WizardAnimations.springGentle, value: progressValue)

                        Text("\(syncedCount) / \(totalCount)")
                            .font(.appSystem(size: 13, weight: .medium, design: .monospaced))
                            .foregroundColor(WizardColors.textPrimary)
                    }

                    Text(progressMessage.isEmpty ? String(localized: "setup.media.syncing") : progressMessage)
                        .font(.appSystem(size: 13))
                        .foregroundColor(WizardColors.textSecondary)
                }
                .padding(20)
                .frame(maxWidth: .infinity)
                .background(WizardColors.bgCard)
                .cornerRadius(12)
            } else if syncCompleted {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(WizardColors.success)
                        .font(.title2)
                    Text(progressMessage.isEmpty ? String(localized: "setup.media.syncSuccess") : progressMessage)
                        .font(.appSystem(size: 15, weight: .medium))
                        .foregroundColor(WizardColors.textPrimary)
                }
                .padding(16)
                .frame(maxWidth: .infinity)
                .background(WizardColors.bgCard)
                .cornerRadius(12)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(WizardColors.success.opacity(0.5), lineWidth: 2))

                WizardPrimaryButton(title: String(localized: "setup.action.continue"), action: onContinue)
            } else {
                WizardInputField(label: String(localized: "setup.media.label.blossomURL"), text: Binding(
                    get: { blossomURL },
                    set: { blossomURL = $0; blossomURLEdited = true }
                ), placeholder: "https://blossom.primal.net")

                WizardPrimaryButton(title: String(localized: "setup.media.syncAction")) {
                    startNetworkSync()
                }
            }
        }
    }

    @ViewBuilder
    private var backupImportContent: some View {
        VStack(spacing: 14) {
            if isSyncing {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(WizardColors.accentPrimary)
                    Text(String(localized: "setup.media.importing"))
                        .font(.appSystem(size: 14))
                        .foregroundColor(WizardColors.textSecondary)
                }
                .padding(16)
                .frame(maxWidth: .infinity)
                .background(WizardColors.bgCard)
                .cornerRadius(12)
            } else if syncCompleted {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(WizardColors.success)
                        .font(.title2)
                    Text(String(localized: "setup.media.importSuccess"))
                        .font(.appSystem(size: 15, weight: .medium))
                        .foregroundColor(WizardColors.textPrimary)
                }
                .padding(16)
                .frame(maxWidth: .infinity)
                .background(WizardColors.bgCard)
                .cornerRadius(12)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(WizardColors.success.opacity(0.5), lineWidth: 2))

                WizardPrimaryButton(title: String(localized: "setup.action.continue"), action: onContinue)
            } else {
                Button(action: {
                    #if os(macOS)
                    NSApp.activate(ignoringOtherApps: true)
                    #endif
                    showingFileImporter = true
                }) {
                    HStack {
                        Image(systemName: "doc.zipper")
                            .font(.title3)
                        Text(String(localized: "setup.media.chooseArchive"))
                            .font(.appSystem(size: 15, weight: .medium))
                    }
                    .foregroundColor(WizardColors.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(24)
                    .background(WizardColors.bgCard)
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [8, 4]))
                            .foregroundColor(WizardColors.borderSubtle)
                    )
                }
                .buttonStyle(.plain)

                Text(String(localized: "setup.media.backupHint"))
                    .font(.appSystem(size: 12))
                    .foregroundColor(WizardColors.textMuted)
            }
        }
    }

    private func startNetworkSync() {
        isSyncing = true
        progressMessage = "Connecting..."
        progressValue = 0
        syncedCount = 0
        totalCount = 0

        let trimmedURL = blossomURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty, let _ = URL(string: trimmedURL) else {
            syncError = "Invalid media server URL."
            showSyncError = true
            isSyncing = false
            return
        }

        Task {
            await useServer(trimmedURL)
            let blossomService = BlossomService(configService: configService, nostrService: nostrService)
            let mirroredCount = await blossomService.mirrorAllFromExternal { completed, total in
                syncedCount = completed
                totalCount = total
                progressValue = total > 0 ? Double(completed) / Double(total) : 0
                progressMessage = "Mirrored \(completed) of \(total) files..."
            }

            isSyncing = false
            syncCompleted = true
            progressMessage = "Synced \(mirroredCount) files."
        }
    }

    /// The owner's newest media server list (kind 10063). `known` false: the
    /// relays could not say whether they have one.
    private func theirServerList() async -> (servers: [String], known: Bool) {
        let owner = nostrService.activeHexPubkey
        guard !owner.isEmpty else { return ([], false) }
        let lookup = await nostrService.lookupNewestReplaceable(
            kind: 10063, for: owner, alsoAsk: [RelayConfiguration.serverListIndexerRelay])
        if let event = lookup.event {
            return (ProfileRepository.parseServerListTags(event.tags), true)
        }
        return ([], lookup.confirmedNone)
    }

    /// Their first server in the field, in place of the Primal suggestion.
    private func prefillFromTheirList() async {
        guard let first = await theirServerList().servers.first(where: { $0.lowercased().hasPrefix("https://") }),
              !blossomURLEdited, !isSyncing else { return }
        blossomURL = first
    }

    /// Syncs from `url`. A list the owner already has is never signed over
    /// here (Logen, 2026-10-31): their servers come in first, in their order
    /// (`syncOwnerServerList`, no publish), and the server typed here is only
    /// added for uploads on this device. A new 10063 goes out only when the
    /// relays confirmed the account has none.
    private func useServer(_ url: String) async {
        let theirs = await theirServerList()
        if !theirs.servers.isEmpty { await nostrService.syncOwnerServerList() }
        guard !configService.config.blossomMirrors.contains(url) else { return }
        configService.config.blossomMirrors.append(url)
        configService.save()
        if theirs.servers.isEmpty && theirs.known { nostrService.publishServerList() }
    }

    private func importMedia(from url: URL) {
        isSyncing = true
        guard url.startAccessingSecurityScopedResource() else {
            syncError = "Permission denied to access the file."
            showSyncError = true
            isSyncing = false
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
            syncError = "Failed to copy media archive: \(error.localizedDescription)"
            showSyncError = true
            isSyncing = false
            return
        }

        RelayProcessManager.shared.runBlossomImportStrippingExtensions(config: configService.config, inputPath: tempFile.path) { success in
            try? FileManager.default.removeItem(at: tempFile)
            Task { @MainActor in
                isSyncing = false
                if success {
                    syncCompleted = true
                } else {
                    syncError = "Failed to import media. Check logs for details."
                    showSyncError = true
                }
            }
        }
    }
}
