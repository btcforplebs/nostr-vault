import SwiftUI

/// The Preview half of the article and recipe editor: the post as readers
/// will see it, drawn by the same markdown renderer the reader uses, so
/// headings, lists and links can be checked before publishing.
struct LongFormPreviewSection: View {
    let title: String
    let summary: String
    let markdown: String

    private func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                if !trimmed(title).isEmpty {
                    Text(trimmed(title))
                        .font(.appSystem(size: 24, weight: .bold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !trimmed(summary).isEmpty {
                    Text(trimmed(summary))
                        .font(.appSystem(size: 15))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if trimmed(markdown).isEmpty {
                    Text("Nothing to preview yet.")
                        .foregroundColor(.secondary)
                } else {
                    MarkdownBodyView(markdown: markdown)
                }
            }
            .padding(.vertical, 8)
            .textSelection(.enabled)
        } header: {
            Text("Preview")
        }
    }
}
