import SwiftUI

/// The paragraph a highlight starts from; the sheet lets the reader trim it.
struct HighlightDraft: Identifiable {
    let id = UUID()
    let context: String
}

/// Edit the highlighted passage down to the part that matters and optionally
/// add a thought, which makes it a quote highlight.
struct HighlightSheet: View {
    let draft: HighlightDraft
    let onPublish: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var passage = ""
    @State private var comment = ""

    private var canPublish: Bool { !passage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $passage)
                        .font(.appSystem(size: 16))
                        .frame(minHeight: 140)
                } header: {
                    Text("Highlight")
                } footer: {
                    Text("Delete what you don't want to keep.")
                }
                Section("Your thoughts (optional)") {
                    TextField("Add a comment", text: $comment, axis: .vertical)
                        .lineLimit(2...5)
                }
            }
            .navigationTitle("Highlight")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Publish") {
                        onPublish(passage, comment)
                        dismiss()
                    }
                    .disabled(!canPublish)
                }
            }
        }
        .onAppear { if passage.isEmpty { passage = draft.context } }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 380)
        #endif
    }
}
