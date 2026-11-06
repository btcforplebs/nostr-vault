import SwiftUI

/// The copy's saving and relay catch-up stages: a sliding bar (the engine
/// has no moving byte count while it saves notes) with the notes and photos
/// counted so far, and Skip, which goes in now while the saving and the relay
/// catch-up carry on in the background.
struct CopySavingProgress: View {
    let progress: MeshCopyV2.Progress
    let onSkip: () -> Void

    @State private var notes: Int?
    @State private var skipped = false

    var body: some View {
        VStack(spacing: 10) {
            SlidingBar()
            if let line = CopySaving.countsLine(notes: notes, progress: progress) {
                Text(line)
                    .font(.appSystem(size: 13, weight: .medium))
                    .foregroundColor(WizardColors.textSecondary)
                    .monospacedDigit()
                    .multilineTextAlignment(.center)
            }
            if CopySaving.canSkip(progress) {
                Button(skipped ? "Skipping…" : "Skip") {
                    skipped = true
                    onSkip()
                }
                .buttonStyle(.plain)
                .foregroundColor(WizardColors.accentPrimary)
                .frame(minHeight: 44)
                .disabled(skipped)
            }
        }
        .task { await countNotes() }
    }

    /// The vault's saved total every few seconds while this is on screen:
    /// every event in every store this device can count (public, inbox, and
    /// /private + /chat when it can sign as the owner), like the Vault tab's
    /// total. Counting only kind 1 in the public store sat at a few hundred
    /// while tens of thousands were saved elsewhere (iPad, 2026-11-06). A
    /// store that doesn't answer keeps its last count, so the line never
    /// drops back.
    private func countNotes() async {
        var last: [URL: Int] = [:]
        while !Task.isCancelled {
            let urls = Self.storeURLs
            await withTaskGroup(of: (URL, Int?).self) { group in
                for url in urls {
                    group.addTask { (url, await RelayCounter.count(["all": [:]], at: url, timeout: 10)?["all"]) }
                }
                for await (url, got) in group {
                    if let got { last[url] = max(got, last[url] ?? 0) }
                }
            }
            if !last.isEmpty { notes = max(last.values.reduce(0, +), notes ?? 0) }
            try? await Task.sleep(nanoseconds: UInt64(CopySaving.countEvery * 1_000_000_000))
        }
    }

    private static var storeURLs: [URL] {
        let port = ConfigService.shared.config.relayPort
        #if os(macOS)
        let base = URL(string: "ws://127.0.0.1:\(port)")
        #else
        let base = URL(string: "wss://127.0.0.1:\(port)")
        #endif
        guard let base else { return [] }
        return RelayCountSession.countable(
            CopySaving.storePaths.map { $0.isEmpty ? base : base.appendingPathComponent($0) },
            canSignAsOwner: RelayCounter.ownerCanAuth())
    }
}

/// An indeterminate bar that keeps moving.
private struct SlidingBar: View {
    @State private var at: CGFloat = -0.35

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(WizardColors.bgElevated)
                Capsule()
                    .fill(WizardColors.accentPrimary)
                    .frame(width: geo.size.width * 0.35)
                    .offset(x: geo.size.width * at)
            }
            .clipShape(Capsule())
        }
        .frame(height: 6)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: false)) { at = 1 }
        }
        .accessibilityLabel("Saving")
    }
}
