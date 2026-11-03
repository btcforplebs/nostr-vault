import SwiftUI

/// Send privately from the share sheet: the message (the link or text that
/// was shared, editable) and, if this account has sent shares privately
/// before, one of those people. It is queued, not sent: the app shows the
/// recipient and text again and sends only on its button.
struct DMShareForm: View {
    let input: NVShareInput
    let account: String?
    let send: ([String: String]) -> Void

    @State private var message = ""
    @State private var to: String?
    @State private var started = false

    private var recent: [NVShareContactsSnapshot.Contact] {
        NVShareContactsSnapshot.read()?.contacts(for: account) ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Send privately").font(.subheadline.weight(.semibold))
            TextEditor(text: $message)
                .frame(minHeight: 90, maxHeight: 160)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(.separator)))
            let people = recent
            if !people.isEmpty {
                Picker("To", selection: $to) {
                    Text("Choose in the app").tag(String?.none)
                    ForEach(people, id: \.npub) { c in
                        Text(c.name.isEmpty ? String(c.npub.prefix(16)) + "…" : c.name).tag(Optional(c.npub))
                    }
                }
                .pickerStyle(.menu)
            }
            Button {
                var form = ["message": message]
                if let to { form["to"] = to }
                send(form)
            } label: {
                Text("Send to Nostr Vault").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Text("You'll pick or check who it goes to in the app, and it is sent only from there.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear {
            guard !started else { return }
            started = true
            if let url = NVShareClassifier.webURL(of: input) {
                let title = input.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                message = title.isEmpty ? url : "\(title)\n\(url)"
            } else {
                message = input.selection ?? input.text ?? ""
            }
        }
    }
}
