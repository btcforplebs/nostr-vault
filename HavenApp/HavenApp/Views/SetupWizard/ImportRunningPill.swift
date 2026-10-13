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
            // Ambient: shows only while nothing else is in the lane.
            PillSlot("importRunning", level: .ambient) {
                let stage = ImportTourStage(statusMessage: relayManager.importStatusMessage, completed: false)
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini).tint(.white)
                    Text("Importing · \(Self.shortText(stage))")
                        .lineLimit(1)
                }
                .pillCapsule(.accent, size: .small)
                .allowsHitTesting(false)
                .accessibilityElement(children: .combine)
            }
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
