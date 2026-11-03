import SwiftUI

/// Highlight from the share sheet: the passage (Safari's selection, or text
/// another app sent), an optional thought, and who it is from. It is queued,
/// not published: the app shows it again before signing.
struct HighlightShareForm: View {
    let input: NVShareInput
    let accounts: [NVShareAccountsSnapshot.Account]
    @Binding var account: String?
    let send: ([String: String]) -> Void

    @State private var passage = ""
    @State private var comment = ""
    @State private var started = false

    private var canSend: Bool { !passage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let url = NVShareClassifier.webURL(of: input) {
                Text(url).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Text("Highlight").font(.subheadline.weight(.semibold))
            TextEditor(text: $passage)
                .frame(minHeight: 110, maxHeight: 200)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(.separator)))
                .overlay(alignment: .topLeading) {
                    if passage.isEmpty {
                        Text("Paste or type the part worth keeping")
                            .foregroundStyle(.tertiary).padding(8).allowsHitTesting(false)
                    }
                }
            TextField("Your thoughts (optional)", text: $comment, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
            if accounts.count > 1 {
                Picker("Post as", selection: $account) {
                    ForEach(accounts, id: \.npub) { a in
                        Text(a.name.isEmpty ? String(a.npub.prefix(16)) + "…" : a.name).tag(Optional(a.npub))
                    }
                }
                .pickerStyle(.menu)
            }
            Button {
                send(["passage": passage, "comment": comment])
            } label: {
                Text("Send to Nostr Vault").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSend)
            Text("You'll see it once more in the app before it is posted.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear {
            guard !started else { return }
            started = true
            passage = input.selection ?? ((NVShareClassifier.webURL(of: input) == nil) ? (input.text ?? "") : "")
        }
    }
}
