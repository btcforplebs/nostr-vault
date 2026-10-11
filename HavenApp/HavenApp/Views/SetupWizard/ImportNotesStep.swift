import SwiftUI
import UniformTypeIdentifiers

// MARK: - Keep screen awake

private extension View {
    /// Disables the iOS idle timer while this view is on screen. No-op on macOS.
    func keepsScreenAwake() -> some View {
        #if os(iOS)
        onAppear { UIApplication.shared.isIdleTimerDisabled = true }
            .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        #else
        self
        #endif
    }
}

// MARK: - Step 4: Import Notes

struct ImportNotesStep: View {
    @EnvironmentObject var relayManager: RelayProcessManager
    @EnvironmentObject var configService: ConfigService
    let onContinue: () -> Void
    let onSkip: () -> Void

    @State private var appeared = false
    @State private var activeTab = 0 // 0 = Network, 1 = Backup
    @State private var showingFileImporter = false
    @State private var isRestoring = false
    @State private var restoreCompleted = false
    @State private var restoreError: String?
    @State private var showRestoreError = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer().frame(height: 20)

            Text(String(localized: "setup.import.title"))
                .font(.appSystem(size: isIOSDevice ? 24 : 28, weight: .semibold))
                .foregroundColor(WizardColors.textPrimary)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 10)
                .animation(WizardAnimations.springEnter.delay(0.1), value: appeared)

            Text(String(localized: "setup.import.subtitle"))
                .font(.appSystem(size: 15))
                .foregroundColor(WizardColors.textSecondary)
                .multilineTextAlignment(.center)
                .opacity(appeared ? 1 : 0)
                .animation(WizardAnimations.fadeIn.delay(0.2), value: appeared)

            // Tab bar
            HStack(spacing: 4) {
                tabPill(String(localized: "setup.import.tab.network"), isActive: activeTab == 0) { activeTab = 0 }
                tabPill(String(localized: "setup.import.tab.backup"), isActive: activeTab == 1) { activeTab = 1 }
            }
            .padding(3)
            .background(WizardColors.bgCard)
            .cornerRadius(10)
            .opacity(appeared ? 1 : 0)
            .animation(WizardAnimations.fadeIn.delay(0.25), value: appeared)

            // Tab content
            Group {
                if activeTab == 0 {
                    networkImportContent
                } else {
                    backupRestoreContent
                }
            }
            .opacity(appeared ? 1 : 0)
            .animation(WizardAnimations.fadeIn.delay(0.3), value: appeared)

            WizardSkipLink(title: String(localized: "setup.import.skip")) { onSkip() }

            Spacer().frame(height: 8)
        }
        .onAppear { appeared = true }
        // Importing can run 20+ minutes; don't let the screen dim or lock while it's up.
        .keepsScreenAwake()
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
                restoreError = error.localizedDescription
                showRestoreError = true
            }
        }
        .alert(String(localized: "setup.import.alert.restoreFailed"), isPresented: $showRestoreError) {
            Button(String(localized: "setup.alert.ok"), role: .cancel) {}
        } message: {
            Text(restoreError ?? "Unknown error")
        }
        .alert(String(localized: "setup.import.alert.portConflict"), isPresented: $relayManager.isPortConflict) {
            Button(String(localized: "setup.import.alert.retry")) {
                relayManager.isPortConflict = false
                relayManager.importNotes(config: configService.config)
            }
            Button(String(localized: "setup.action.cancel"), role: .cancel) {
                relayManager.isPortConflict = false
                relayManager.cancelImport()
            }
        } message: {
            Text("Port \(configService.config.relayPort) is currently in use. Stop the other process or change the port in Settings.")
        }
    }

    @ViewBuilder
    private var networkImportContent: some View {
        VStack(spacing: 14) {
            if relayManager.isImporting || relayManager.importCompleted {
                VStack(spacing: 12) {
                    HStack {
                        Text(relayManager.importCompleted ? String(localized: "setup.import.done") : String(localized: "setup.import.importing"))
                            .font(.appSystem(size: 13))
                            .foregroundColor(WizardColors.textSecondary)
                        Spacer()
                        Text("\(Int(relayManager.importProgress * 100))%")
                            .font(.appSystem(size: 13, design: .monospaced))
                            .foregroundColor(WizardColors.accentPrimary)
                    }

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(WizardColors.bgElevated)
                                .frame(height: 6)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(WizardColors.accentGradient)
                                .frame(width: geo.size.width * relayManager.importProgress, height: 6)
                        }
                    }
                    .frame(height: 6)

                    if !relayManager.importCompleted {
                        Text(relayManager.importStatusMessage)
                            .font(.appSystem(size: 12))
                            .foregroundColor(WizardColors.textMuted)
                            .lineLimit(2)
                    }

                    if relayManager.importCompleted {
                        WizardPrimaryButton(title: String(localized: "setup.action.continue"), action: onContinue)
                    } else {
                        Button(action: { relayManager.cancelImport() }) {
                            Text(String(localized: "setup.import.cancelImport"))
                                .font(.appSystem(size: 14, weight: .medium))
                                .foregroundColor(WizardColors.error)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
                .background(WizardColors.bgCard)
                .cornerRadius(12)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(WizardColors.borderSubtle, lineWidth: 1))
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    DatePicker(String(localized: "setup.import.startDate"), selection: Binding(
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
                    .font(.appSystem(size: 14))
                    .foregroundColor(WizardColors.textPrimary)
                    .colorScheme(.dark)

                    Divider().background(WizardColors.borderSubtle)

                    Text(String(localized: "setup.import.seedRelays"))
                        .font(.appSystem(size: 14, weight: .semibold))
                        .foregroundColor(WizardColors.textPrimary)

                    RelayListEditor(relays: $configService.config.importSeedRelays)
                        .frame(minHeight: 80, maxHeight: 120)
                        .cornerRadius(8)
                }
                .padding(16)
                .background(WizardColors.bgCard)
                .cornerRadius(12)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(WizardColors.borderSubtle, lineWidth: 1))

                WizardPrimaryButton(title: String(localized: "setup.import.action")) {
                    configService.save()
                    relayManager.importNotes(config: configService.config)
                }
            }
        }
    }

    @ViewBuilder
    private var backupRestoreContent: some View {
        VStack(spacing: 14) {
            if isRestoring {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(WizardColors.accentPrimary)
                    Text(String(localized: "setup.import.restoring"))
                        .font(.appSystem(size: 14))
                        .foregroundColor(WizardColors.textSecondary)
                }
                .padding(16)
                .frame(maxWidth: .infinity)
                .background(WizardColors.bgCard)
                .cornerRadius(12)
            } else if restoreCompleted {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(WizardColors.success)
                        .font(.title2)
                    Text(String(localized: "setup.import.restoreSuccess"))
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
                        Text(String(localized: "setup.import.chooseBackup"))
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

                Text(String(localized: "setup.import.backupHint"))
                    .font(.appSystem(size: 12))
                    .foregroundColor(WizardColors.textMuted)
            }
        }
    }

    private func restoreBackup(from url: URL) {
        isRestoring = true
        guard url.startAccessingSecurityScopedResource() else {
            restoreError = "Permission denied to access the file."
            showRestoreError = true
            isRestoring = false
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }

        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent(url.lastPathComponent)

        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var copyError: Error?

        coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { safeURL in
            do {
                if FileManager.default.fileExists(atPath: tempFile.path) {
                    try FileManager.default.removeItem(at: tempFile)
                }
                try FileManager.default.copyItem(at: safeURL, to: tempFile)
            } catch {
                copyError = error
            }
        }

        if let error = coordinationError ?? copyError {
            restoreError = "Failed to copy backup file: \(error.localizedDescription)"
            showRestoreError = true
            isRestoring = false
            return
        }

        configService.save()
        RelayProcessManager.shared.runBackupRestore(config: configService.config, inputPath: tempFile.path) { success in
            try? FileManager.default.removeItem(at: tempFile)
            Task { @MainActor in
                isRestoring = false
                if success {
                    configService.reload()
                    restoreCompleted = true
                } else {
                    restoreError = "Failed to restore backup. Check logs for details."
                    showRestoreError = true
                }
            }
        }
    }
}
