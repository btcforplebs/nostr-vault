import SwiftUI

/// The inbox's last row when muted words hide conversations: how many, and
/// a button to show them (or hide them again). Nothing shows when none are
/// hidden. Android: DMMutedWordsRow.kt.
struct DMMutedWordsRow: View {
    @ObservedObject var dmService: DMService

    var body: some View {
        let count = dmService.mutedWordConversations.count
        if count > 0 {
            Button {
                dmService.showsMutedWordConversations.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "eye.slash")
                        .foregroundColor(.secondary)
                        .accessibilityHidden(true)
                    Text(count == 1 ? "1 conversation hidden by a muted word"
                                    : "\(count) conversations hidden by muted words")
                        .font(.appSystem(size: 13))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(dmService.showsMutedWordConversations ? "Hide" : "Show")
                        .font(.appSystem(size: 13, weight: .semibold))
                        .foregroundColor(.accentColor)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(dmService.showsMutedWordConversations
                               ? "Hides them again" : "Shows them in the inbox")
        }
    }
}
