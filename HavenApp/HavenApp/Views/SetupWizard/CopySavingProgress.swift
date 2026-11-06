import SwiftUI

/// The copy's saving and relay catch-up stages: a sliding bar (the engine
/// has no moving byte count while it saves notes) with the notes and photos
/// counted so far, and Skip for the relay catch-up.
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

    /// The vault's note count every few seconds while this is on screen.
    private func countNotes() async {
        while !Task.isCancelled {
            if let url = Self.relayURL,
               let got = await RelayCounter.count(["notes": ["kinds": [1]]], at: url, timeout: 10)?["notes"] {
                notes = got
            }
            try? await Task.sleep(nanoseconds: UInt64(CopySaving.countEvery * 1_000_000_000))
        }
    }

    private static var relayURL: URL? {
        let port = ConfigService.shared.config.relayPort
        #if os(macOS)
        return URL(string: "ws://127.0.0.1:\(port)")
        #else
        return URL(string: "wss://127.0.0.1:\(port)")
        #endif
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
