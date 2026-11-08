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
    @ObservedObject private var jobs = ImportJobsService.shared
    let onContinue: () -> Void
    let onSkip: () -> Void

    @State private var appeared = false
    /// Their own servers (kind 10002 write relays), read for this import
    /// only: never saved or published.
    @State private var ownRelays: [String] = []
    /// Import was tapped: first run's setup job (ImportJobs) is on.
    @State private var requested = false

    /// Setup let them in: done or partial.
    private var setupDone: Bool {
        if case .finished = jobs.setupStage { return true }
        return false
    }
    private var setupFailed: String? {
        if case .couldNotFinish(let reason) = jobs.setupStage { return ImportJobs.couldNotFinishText(reason: reason) }
        return nil
    }

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

            // A backup zip is restored from the Vault tab, not in setup (Logen 2026-11-05).
            networkImportContent
            .opacity(appeared ? 1 : 0)
            .animation(WizardAnimations.fadeIn.delay(0.3), value: appeared)

            WizardSkipLink(title: String(localized: "setup.import.skip")) {
                // A setup already asked for carries on in the running relay.
                if requested { relayManager.endFirstRun() }
                onSkip()
            }

            Spacer().frame(height: 8)
        }
        .onAppear { appeared = true }
        .task { await loadOwnRelays() }
        // Don't let the screen dim or lock while setup is up.
        .keepsScreenAwake()
        .alert(String(localized: "setup.import.alert.portConflict"), isPresented: $relayManager.isPortConflict) {
            Button(String(localized: "setup.import.alert.retry")) {
                relayManager.isPortConflict = false
                startSetup()
            }
            Button(String(localized: "setup.action.cancel"), role: .cancel) {
                relayManager.isPortConflict = false
                relayManager.cancelFirstRunSetup()
            }
        } message: {
            Text("Port \(configService.config.relayPort) is currently in use. Stop the other process or change the port in Settings.")
        }
    }

    @ViewBuilder
    private var networkImportContent: some View {
        VStack(spacing: 14) {
            if requested {
                VStack(spacing: 12) {
                    HStack {
                        Text(setupDone ? String(localized: "setup.import.done") : String(localized: "setup.import.importing"))
                            .font(.appSystem(size: 13))
                            .foregroundColor(WizardColors.textSecondary)
                        Spacer()
                    }

                    // setup reports no progress of its own, and takes seconds.
                    if setupDone || setupFailed != nil {
                        ProgressView(value: 1)
                            .tint(setupFailed != nil ? .orange : WizardColors.accentPrimary)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                            .tint(WizardColors.accentPrimary)
                    }

                    if let setupFailed {
                        Text(setupFailed)
                            .font(.appSystem(size: 12))
                            .foregroundColor(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        ImportCouldNotStartButton(action: startSetup)
                    } else if jobs.setupStage == .finished(partial: true) {
                        Text(ImportTourStep.partialLine)
                            .font(.appSystem(size: 12))
                            .foregroundColor(WizardColors.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if !setupDone {
                        Text("Bringing in your notes…")
                            .font(.appSystem(size: 12))
                            .foregroundColor(WizardColors.textMuted)
                            .lineLimit(2)
                    }

                    if setupDone {
                        WizardPrimaryButton(title: String(localized: "setup.action.continue")) {
                            relayManager.endFirstRun()
                            onContinue()
                        }
                    } else if setupFailed == nil {
                        Button(action: { relayManager.cancelFirstRunSetup() }) {
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

                    ownRelaysNote
                        .frame(minHeight: 80, maxHeight: 120)
                        .cornerRadius(8)
                }
                .padding(16)
                .background(WizardColors.bgCard)
                .cornerRadius(12)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(WizardColors.borderSubtle, lineWidth: 1))

                WizardPrimaryButton(title: String(localized: "setup.import.action")) {
                    configService.save()
                    startSetup()
                }
            }
        }
    }

    private func startSetup() {
        requested = true
        relayManager.startFirstRun(config: configService.config, alsoFrom: ownRelays)
    }

    @ViewBuilder
    private var ownRelaysNote: some View {
        if !ownRelays.isEmpty {
            Text("Also reading from your servers: " + ownRelays.map { RelayMatrix.label($0) }.joined(separator: ", "))
                .font(.appSystem(size: 12))
                .foregroundColor(WizardColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Reads the owner's relay list (kind 10002) for the servers their
    /// notes are on. Nothing is written to it.
    private func loadOwnRelays() async {
        guard let pubkey = NpubValidation.hexPubkey(fromNpub: configService.config.ownerNpub) else { return }
        // The indexers too: a list made in another app may live only there.
        let list = await NostrService.shared.fetchNewestReplaceable(
            kind: 10002, for: pubkey, alsoAsk: configService.config.vaultSeedRelays + RelayDraft.indexers
        )
        ownRelays = RelayCheck.ownWriteRelays(relayListTags: list?.tags ?? [])
    }
}
