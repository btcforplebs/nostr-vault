import SwiftUI

/// A NIP-84 highlight in a timeline: the highlighter's comment, the passage
/// set off by a bar, and a web source as a link card. An article or note it
/// came from is drawn by the row's quote section, under this.
struct HighlightInlineBody: View {
    let note: FeedNote
    let isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let comment = FeedHighlight.comment(tags: note.tags) {
                Text(comment)
                    .font(.appSystem(size: 17))
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Label("Highlighted", systemImage: "highlighter")
                .font(.appSystem(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
            Text(note.content.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.appSystem(size: isFocused ? 19 : 17, design: .serif))
                .italic()
                .foregroundColor(.primary)
                .lineSpacing(3)
                .lineLimit(isFocused ? nil : 8)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.havenPurple.opacity(0.7))
                        .frame(width: 3)
                }
            if let url = FeedHighlight.sourceURL(tags: note.tags) {
                LinkPreviewCard(url: url)
            }
        }
        .padding(.top, 4)
    }
}
