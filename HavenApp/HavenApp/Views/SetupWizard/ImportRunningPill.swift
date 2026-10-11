import SwiftUI

// MARK: - Background pill

/// "Importing · notes from Mar 2024": shown over the app
/// while an import runs after setup (I use Nostr's "Keep it running", or an
/// import started from Settings). Not a button, so it takes no touches.
struct ImportRunningPill: View {
    @ObservedObject private var relayManager = RelayProcessManager.shared
    @ObservedObject private var configService = ConfigService.shared

    var body: some View {
        if relayManager.isImporting && configService.config.hasCompletedSetup {
            let stage = ImportTourStage(statusMessage: relayManager.importStatusMessage, completed: false)
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(.white)
                Text("Importing · \(Self.shortText(stage))")
                    .font(.appSystem(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.black.opacity(0.75)))
            .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 1))
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)
            .transition(.opacity)
        }
    }

    /// "Saving your notes from Mar 2024…" → "notes from Mar 2024".
    static func shortText(_ stage: ImportTourStage) -> String {
        stage.text
            .replacingOccurrences(of: "Saving your ", with: "")
            .replacingOccurrences(of: "Saving ", with: "")
            .replacingOccurrences(of: "Looking through ", with: "")
            .replacingOccurrences(of: "…", with: "")
            .lowercasedFirst
    }
}

private extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}
