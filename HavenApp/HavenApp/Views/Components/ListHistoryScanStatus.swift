import SwiftUI

/// While Moving in looks for older list versions: a Skip button (what was
/// found so far is kept and the import carries on). After: the plain count.
struct ListHistoryScanStatus: View {
    @EnvironmentObject var relayManager: RelayProcessManager
    var textColor: Color = .secondary
    var accent: Color = .accentColor
    /// false where the screen's own status line already says it (the import tour).
    var showsLooking = true

    var body: some View {
        if relayManager.listHistoryScanning {
            HStack(spacing: 8) {
                if showsLooking {
                    Text(ListHistoryScan.lookingStatus)
                        .font(.appSystem(size: 12))
                        .foregroundColor(textColor)
                }
                Spacer(minLength: 8)
                Button("Skip") { relayManager.skipListHistoryScan() }
                    .font(.appSystem(size: 13, weight: .semibold))
                    .foregroundColor(accent)
                    .buttonStyle(.plain)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("import.listHistory.skip")
            }
        } else if let note = relayManager.listHistoryNote {
            Text(note + (note.hasPrefix("Found") ? " See them in Recover a List." : ""))
                .font(.appSystem(size: 12))
                .foregroundColor(textColor)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("import.listHistory.note")
        }
    }
}
