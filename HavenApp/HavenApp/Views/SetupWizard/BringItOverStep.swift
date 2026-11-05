import SwiftUI

// MARK: - Copy from my other vault

/// The two scans with this device as B (lane A's PairDeviceFlow, unchanged),
/// then the copy from the other device with its progress. Anything that
/// fails calls `onFallback`, which goes on quietly to the relay import.
struct BringItOverStep: View {
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var relayManager: RelayProcessManager
    @StateObject private var holder = PairDeviceFlowHolder()

    /// Linked and copied (or copying on in the background).
    let onDone: () -> Void
    /// No link, or the copy stalled: one plain line, then the relay import.
    let onFallback: () -> Void
    /// "Lost your other device?": the relay import, by choice (no line).
    let onRelaysInstead: () -> Void

    @State private var scanning = false
    @State private var other: MeshPairing.Payload?
    @State private var linkStartedAt: Int?
    @State private var copying = false
    @State private var lastProgress: (value: Double, message: String, at: Int)?
    @State private var finished = false
    /// The copy's import was asked for (its outcome is this request's).
    @State private var requested = false

    private static var now: Int { Int(Date().timeIntervalSince1970) }

    var body: some View {
        let flow = holder.flow(configService)
        VStack(spacing: 16) {
            Spacer().frame(height: 12)
            Text(OtherVaultCopy.button)
                .font(.appSystem(size: isIOSDevice ? 24 : 28, weight: .semibold))
                .foregroundColor(WizardColors.textPrimary)
            BringItOverContent(flow: flow, other: other, copying: copying, scanning: $scanning,
                               scanned: scanned, confirm: confirm, onLinked: startCopy, onFailed: fallBack,
                               onContinue: done)
                .environmentObject(relayManager)
            if !copying {
                Button(action: relaysInstead) {
                    Text(OtherVaultCopy.lostDevice)
                        .font(.appSystem(size: 14, weight: .medium))
                        .foregroundColor(WizardColors.accentPrimary)
                        .multilineTextAlignment(.center)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in watch() }
        #if os(macOS)
        .onAppear { MacFipsMeshService.shared.turnOnForCopy() }
        #endif
        .onDisappear {
            if !copying { flow.cancel() }
        }
    }

    /// The other device's code, before lane A's flow takes it: kept for its
    /// name and for the copy.
    private func scanned(_ text: String) -> String? {
        let flow = holder.flow(configService)
        if case .success(let p) = MeshPairing.parse(text, ownMesh: nil) { other = p }
        let refusal = flow.scannedFirstCode(text)
        if refusal == nil { scanning = false }
        return refusal
    }

    private func confirm() {
        linkStartedAt = Self.now
        holder.flow(configService).roleConfirmed()
    }

    /// Linked: copy from the other device, read through its link like any
    /// other relay, by the import that setup already runs.
    private func startCopy() {
        guard !copying, let other else { return }
        copying = true
        lastProgress = (relayManager.importProgress, relayManager.importStatusMessage, Self.now)
        Task {
            guard let url = await Self.vaultURL(other.mesh) else { return fallBack() }
            configService.config.importStartDate = OtherVaultCopy.startDate
            configService.save()
            // Refused when an import is already running: a copy can't join it.
            guard relayManager.importNotes(config: configService.config, alsoFrom: [url], otherVault: url) else {
                return fallBack()
            }
            requested = true
        }
    }

    /// The other device's vault as a local ws:// address, or nil. Never log it.
    private static func vaultURL(_ meshNpub: String) async -> String? {
        #if os(iOS)
        return await FipsMeshService.shared.relayWebsocketURL(meshNpub: meshNpub)
        #else
        guard let base = await MacFipsMeshService.shared.ingressURL(meshNpub: meshNpub) else { return nil }
        return HomeVaultLogic.websocketURL(base: base)?.absoluteString
        #endif
    }

    private func watch() {
        guard !finished else { return }
        let now = Self.now
        if copying {
            // Only haven-go's result line ends it (ImportResult): the other
            // vault not reached, a failed or a cancelled run goes on to the
            // relay import with the "not reached" line; anything else is done
            // (the relay import still runs next, OtherVaultCopy.afterCopied).
            if requested, !relayManager.isImporting, let outcome = relayManager.importOutcome {
                switch outcome.status {
                case .failed, .cancelled: return fallBack()
                case .partial where outcome.otherVaultNotReached: return fallBack()
                case .complete, .partial: return done()
                }
            }
            let value = relayManager.importProgress, message = relayManager.importStatusMessage
            if let last = lastProgress, last.value == value, last.message == message {
                if OtherVaultCopy.isStalled(lastProgressAt: last.at, now: now) { fallBack() }
            } else {
                lastProgress = (value, message, now)
            }
        } else if let started = linkStartedAt, OtherVaultCopy.linkTimedOut(startedAt: started, now: now) {
            fallBack()
        }
    }

    private func done() {
        guard !finished else { return }
        finished = true
        onDone()
    }

    private func relaysInstead() {
        guard !finished else { return }
        finished = true
        holder.flow(configService).cancel()
        onRelaysInstead()
    }

    private func fallBack() {
        guard !finished else { return }
        finished = true
        if !copying { holder.flow(configService).cancel() }
        onFallback()
    }
}

private struct BringItOverContent: View {
    @ObservedObject var flow: PairDeviceFlow
    @EnvironmentObject var relayManager: RelayProcessManager
    let other: MeshPairing.Payload?
    let copying: Bool
    @Binding var scanning: Bool
    let scanned: (String) -> String?
    let confirm: () -> Void
    let onLinked: () -> Void
    let onFailed: () -> Void
    let onContinue: () -> Void

    private var otherName: String {
        let n = other?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return n.isEmpty ? "your other device" : n
    }

    var body: some View {
        VStack(spacing: 16) {
            if copying {
                copyProgress
            } else {
                steps
            }
        }
        .onChange(of: flow.step) { _, step in
            switch step {
            case .linked: onLinked()
            case .failed: onFailed()
            default: break
            }
        }
    }

    @ViewBuilder
    private var steps: some View {
        switch flow.step {
        case .start:
            line("On your other device, open Your devices on its dashboard, tap Add and then Show my code.")
            if scanning {
                PairScanView(title: "Point the camera at your other device's code", validate: scanned,
                             onCancel: { scanning = false }) { _ in }
            } else {
                WizardPrimaryButton(title: "Scan its code") { scanning = true }
            }
        case .confirmRole:
            line(MeshPairing.roleConfirmText(role: other?.role ?? .phone, name: other?.name ?? "", setup: true))
            WizardPrimaryButton(title: "Add", action: confirm)
            Button("Cancel") { flow.cancel() }
                .buttonStyle(.plain)
                .foregroundColor(WizardColors.textSecondary)
        case .joined(let qr, _, let words, let short, let needsWordsTap):
            PairShowQRView(qr: qr, caption: "Now let \(otherName) scan this code.", secondsLeft: nil)
            if needsWordsTap {
                PairCheckWordsView(words: words, short: short,
                                   caption: "Check that \(otherName) shows these same words.")
                WizardPrimaryButton(title: "They match") { flow.wordsMatch() }
            } else {
                ProgressView().tint(WizardColors.accentPrimary)
            }
        case .linked:
            ProgressView().tint(WizardColors.accentPrimary)
        default:
            ProgressView().tint(WizardColors.accentPrimary)
        }
        if let notice = flow.notice {
            Text(notice)
                .font(.appSystem(size: 13))
                .foregroundColor(.orange)
                .multilineTextAlignment(.center)
        }
    }

    private var copyProgress: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.appSystem(size: 36))
                .foregroundColor(WizardColors.success)
            line("Linked ✓ \(otherName)")
            Text(OtherVaultCopy.copyingLine(other?.name ?? ""))
                .font(.appSystem(size: 15, weight: .medium))
                .foregroundColor(WizardColors.textPrimary)
            ProgressView(value: max(relayManager.importProgress, 0.02))
                .tint(WizardColors.accentPrimary)
            // The import's own status line names the account by npub: not here (§5a).
            line("It carries on if you go ahead now.")
            WizardPrimaryButton(title: "Continue", action: onContinue)
        }
    }

    private func line(_ text: String) -> some View {
        Text(text)
            .font(.appSystem(size: 15))
            .foregroundColor(WizardColors.textSecondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }
}
