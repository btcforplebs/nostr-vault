import SwiftUI

// MARK: - Copy from my other vault

/// The two scans with this device as B (lane A's PairDeviceFlow, unchanged),
/// then the copy from the other device with its progress. Anything that
/// fails calls `onFallback`, which goes on quietly to the relay import.
struct BringItOverStep: View {
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var relayManager: RelayProcessManager
    @StateObject private var holder = PairDeviceFlowHolder()
    @ObservedObject private var copy = MeshCopyV2Service.shared
    @ObservedObject private var accounts = CopyAccountsSync.shared

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
    @State private var finished = false
    /// The copy was asked for, or last moved, at this time (a stall check).
    @State private var lastMoveAt: Int?
    /// The copy stopped with a line to show; Continue goes on to the relays.
    @State private var stopLine: String?
    /// The copy is done and brought accounts this device lacks: ask first.
    @State private var asking = false

    private static var now: Int { Int(Date().timeIntervalSince1970) }

    var body: some View {
        let flow = holder.flow(configService)
        VStack(spacing: 16) {
            Spacer().frame(height: 12)
            Text(OtherVaultCopy.button)
                .font(.appSystem(size: isIOSDevice ? 24 : 28, weight: .semibold))
                .foregroundColor(WizardColors.textPrimary)
            if asking {
                CopyAccountsAskView(accounts: accounts.offered) { ticked in
                    accounts.answer(ticked: ticked)
                    asking = false
                    done()
                }
            } else {
                BringItOverContent(flow: flow, other: other, copying: copying, progress: copy.progress,
                                   retrying: MeshCopyV2.unreachableLine(copy.unreachable, name: other?.name ?? ""),
                                   stopLine: stopLine, scanning: $scanning,
                                   scanned: scanned, confirm: confirm, onLinked: startCopy, onFailed: fallBack,
                                   onContinue: { stopLine == nil ? done() : fallBack() },
                                   onTryAgain: copy.unreachable == .gaveUp ? tryAgain : nil,
                                   onSkip: done)
                    .environmentObject(relayManager)
            }
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
        .onChange(of: copy.progress) { _, p in moved(p) }
        .onChange(of: copy.unreachable) { _, r in unreachableChanged(r) }
        // The local-network prompt comes now, before the scan, not over
        // the copy's progress (Logen, 2026-11-06).
        .onAppear { LocalNetworkPermission.ask() }
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

    /// Linked: PairDeviceFlow has started the copy on this side (B) with the
    /// engine's copy v2 (MeshCopyV2Service). This only follows it; a second
    /// start for the same device does nothing. The vault keeps running.
    private func startCopy() {
        guard !copying, let other else { return }
        copying = true
        lastMoveAt = Self.now
        configService.config.importStartDate = OtherVaultCopy.startDate
        configService.save()
        Task {
            let result = await copy.start(peer: other.mesh, name: other.name)
            if !result.isRunning { fallBack() }
        }
    }

    /// A `COPY` line: the copy finished (the relay catch-up or done) goes
    /// in, a stop with words shows them, anything else is progress. The
    /// catch-up carries on in the background (Logen, 2026-11-06 15:28Z).
    private func moved(_ p: MeshCopyV2.Progress?) {
        guard copying, !finished, let p else { return }
        lastMoveAt = Self.now
        if CopySaving.copyFinished(p) { return done() }
        guard p.isFinished else { return }
        // Can't reach it yet: the service keeps trying, then says it failed.
        if copy.unreachable != .none { return unreachableChanged(copy.unreachable) }
        if let line = MeshCopyV2.message(for: p, name: other?.name ?? "") {
            stopLine = line
        } else {
            fallBack()
        }
    }

    private func watch() {
        // The copy is done while the ask is up: no more lines come, and that is not a stall.
        guard !finished, !asking else { return }
        let now = Self.now
        if copying {
            // No COPY line this long after the last one is a stall; a stop
            // with words waits for Continue.
            // Saving sends no lines until it ends: not a stall either.
            guard stopLine == nil, CopySaving.mayStall(copy.progress), let lastMoveAt else { return }
            // Dialling, waiting for the relay and trying again count as moving.
            if copy.starting || copy.unreachable != .none { self.lastMoveAt = now; return }
            if OtherVaultCopy.isStalled(lastProgressAt: lastMoveAt, now: now) { fallBack() }
        } else if let started = linkStartedAt, OtherVaultCopy.linkTimedOut(startedAt: started, now: now) {
            fallBack()
        }
    }

    /// Still trying: progress shows the line. Tried for minutes: failed,
    /// with Try again and Continue (the relays).
    private func unreachableChanged(_ r: MeshCopyV2.Retry) {
        guard copying, !finished else { return }
        lastMoveAt = Self.now
        stopLine = r == .gaveUp ? MeshCopyV2.unreachableLine(r, name: other?.name ?? "") : nil
    }

    private func tryAgain() {
        stopLine = nil
        lastMoveAt = Self.now
        copy.tryAgain()
    }

    private func done() {
        guard !finished else { return }
        // The copy's accounts this device lacks are asked about before
        // setup goes on (Logen, 2026-11-06); none are added unasked.
        accounts.refreshOffer()
        if !accounts.offered.isEmpty {
            asking = true
            return
        }
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
    let progress: MeshCopyV2.Progress?
    /// The copy can't reach the other device and keeps trying (its line).
    let retrying: String?
    let stopLine: String?
    @Binding var scanning: Bool
    let scanned: (String) -> String?
    let confirm: () -> Void
    let onLinked: () -> Void
    let onFailed: () -> Void
    let onContinue: () -> Void
    /// The copy failed to reach the other device: start a fresh round of tries.
    let onTryAgain: (() -> Void)?
    /// Skip while saving: in now; saving and the catch-up carry on.
    let onSkip: () -> Void

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
            if let stopLine {
                Text(stopLine)
                    .font(.appSystem(size: 15, weight: .medium))
                    .foregroundColor(.orange)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if let onTryAgain {
                    WizardPrimaryButton(title: "Try again", action: onTryAgain)
                } else {
                    line("Your notes come from your relays instead.")
                }
            } else {
                Text(retrying ?? progress.map { MeshCopyV2.stageLine($0, name: other?.name ?? "") }
                     ?? OtherVaultCopy.copyingLine(other?.name ?? ""))
                    .font(.appSystem(size: 15, weight: .medium))
                    .foregroundColor(WizardColors.textPrimary)
                    .multilineTextAlignment(.center)
                if let progress, CopySaving.slides(progress) {
                    CopySavingProgress(progress: progress, onSkip: onSkip)
                } else if retrying == nil, let fraction = progress?.fraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .tint(WizardColors.accentPrimary)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(WizardColors.accentPrimary)
                }
                line("It carries on if you go ahead now.")
            }
            if onTryAgain != nil {
                Button("Continue without it", action: onContinue)
                    .font(.appSystem(size: 15, weight: .medium))
                    .foregroundColor(WizardColors.accentPrimary)
                    .frame(minHeight: 44)
                    .buttonStyle(.plain)
            } else {
                WizardPrimaryButton(title: "Continue", action: onContinue)
            }
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
