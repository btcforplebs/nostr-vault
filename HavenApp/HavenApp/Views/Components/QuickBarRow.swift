import SwiftUI

/// The picker's top row: the quick bar the reaction button's hold shows.
/// Tap one to react. Edit: tap a slot, then any emoji below to put it there.
/// Android: `QuickBarRow.kt`.
struct QuickBarRow: View {
    let bar: [ReactionPick]
    let editing: Bool
    let editSlot: ReactionPick?
    let onToggleEdit: () -> Void
    let onSlot: (ReactionPick) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.appSystem(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.secondary)
                    .tracking(0.5)
                Spacer()
                Button(editing ? "Done" : "Edit", action: onToggleEdit)
                    .font(.appSystem(size: 13, weight: .semibold))
                    .foregroundColor(.havenPurple)
                    .buttonStyle(.plain)
            }
            HStack(spacing: 12) {
                ForEach(bar, id: \.key) { pick in
                    let chosen = editing && editSlot?.key == pick.key
                    Button { onSlot(pick) } label: {
                        ReactionGlyph(pick, fontSize: 26)
                            .frame(width: 38, height: 38)
                            .background(chosen ? Color.havenPurple.opacity(0.35) : Color.platformTertiaryGroupedBackground)
                            .cornerRadius(10)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(editing && !chosen ? Color.secondary.opacity(0.6) : Color.platformSeparator,
                                            lineWidth: editing ? 1.2 : 0.8)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(editing ? "Change \(pick.content)" : pick.content)
                }
            }
        }
    }

    private var title: String {
        if !editing { return "Quick Reactions" }
        return editSlot == nil ? "Tap the one to change" : "Now tap an emoji below"
    }
}
