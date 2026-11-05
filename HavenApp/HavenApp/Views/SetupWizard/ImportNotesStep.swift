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
    /// Their own servers (kind 10002 write relays), read for this import
    /// only: never saved or published.
    @State private var ownRelays: [String] = []
    /// "Look up and back up my lists": on unless switched off (ListHistoryScan).
    @State private var lookForOldLists = ListHistoryScan.defaultOn

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

            WizardSkipLink(title: String(localized: "setup.import.skip")) { onSkip() }

            Spacer().frame(height: 8)
        }
        .onAppear { appeared = true }
        .task { await loadOwnRelays() }
        // Importing can run 20+ minutes; don't let the screen dim or lock while it's up.
        .keepsScreenAwake()
        .alert(String(localized: "setup.import.alert.portConflict"), isPresented: $relayManager.isPortConflict) {
            Button(String(localized: "setup.import.alert.retry")) {
                relayManager.isPortConflict = false
                relayManager.importNotes(config: configService.config, alsoFrom: ownRelays, listHistory: lookForOldLists)
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

                    ListHistoryScanStatus(textColor: WizardColors.textSecondary, accent: WizardColors.accentPrimary)

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

                    ownRelaysNote
                        .frame(minHeight: 80, maxHeight: 120)
                        .cornerRadius(8)

                    Divider().background(WizardColors.borderSubtle)

                    ListHistoryOptInToggle(isOn: $lookForOldLists, textColor: WizardColors.textSecondary)
                        .tint(WizardColors.accentPrimary)
                }
                .padding(16)
                .background(WizardColors.bgCard)
                .cornerRadius(12)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(WizardColors.borderSubtle, lineWidth: 1))

                WizardPrimaryButton(title: String(localized: "setup.import.action")) {
                    configService.save()
                    relayManager.importNotes(config: configService.config, alsoFrom: ownRelays, listHistory: lookForOldLists)
                }
            }
        }
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
            kind: 10002, for: pubkey, alsoAsk: configService.config.importSeedRelays + RelayDraft.indexers
        )
        ownRelays = RelayCheck.ownWriteRelays(relayListTags: list?.tags ?? [])
    }
}
