import SwiftUI

/// Review a "Send privately" share: who it goes to (picked here, or the one
/// the share sheet suggested), and the exact text. Sent as a NIP-17 private
/// message only when Send is tapped.
struct DMReviewView: View {
    let intent: NVShareIntent
    let close: () -> Void

    @ObservedObject private var nostr = NostrService.shared
    @ObservedObject private var dm = DMService.shared
    @State private var started = false
    @State private var message = ""
    @State private var recipient: String?
    @State private var search = ""
    @State private var sending = false
    @State private var sent = false
    @State private var error: String?

    private var npub: String { DMShareHandler.account(for: intent) }
    private var canSend: Bool {
        recipient != nil && !sending && !sent && DMShareAccountRow.isReady(npub)
            && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Form {
            Section("To") {
                if let recipient {
                    HStack {
                        person(recipient)
                        Spacer()
                        if !sent {
                            Button { self.recipient = nil } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                                .accessibilityLabel("Change recipient")
                        }
                    }
                } else {
                    TextField("Name or npub", text: $search)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    ForEach(candidates, id: \.self) { hex in
                        Button { recipient = hex; search = "" } label: { person(hex) }.buttonStyle(.plain)
                    }
                }
            }
            Section {
                TextEditor(text: $message).frame(minHeight: 120).disabled(sent)
            } header: {
                Text("Message")
            } footer: {
                Text(intent.files.isEmpty ? "Only they can read it."
                     : "Only they can read it. Files aren't sent privately yet; only the text goes.")
            }
            DMShareAccountRow(npub: npub, title: "Sending as")
            if let error { Section { Text(error).foregroundStyle(.red).font(.footnote) } }
            Section {
                if sent {
                    Label("Sent.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Button("Done", action: close)
                } else {
                    Button(action: send) {
                        HStack {
                            Spacer()
                            if sending { ProgressView() } else { Text("Send privately").font(.headline) }
                            Spacer()
                        }
                    }
                    .disabled(!canSend)
                }
            }
        }
        .onAppear {
            guard !started else { return }
            started = true
            message = DMShareHandler.initialMessage(intent)
            recipient = DMShareHandler.initialRecipientHex(intent)
        }
    }

    /// Empty search: recent share recipients, then recent conversations.
    /// Otherwise names on this device, or the pasted npub.
    private var candidates: [String] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.lowercased().hasPrefix("npub1") {
            guard let d = Bech32.decode(q), d.hrp == "npub" else { return [] }
            return [d.hexString]
        }
        if q.count >= 2 {
            let lower = q.lowercased()
            return Array(nostr.profiles.filter { ($0.value.bestName).lowercased().contains(lower) }.keys.sorted().prefix(10))
        }
        let recent = (NVShareContactsSnapshot.read()?.contacts(for: npub) ?? []).compactMap { Bech32.decode($0.npub)?.hexString }
        var seen = Set<String>()
        return (recent + dm.visibleConversations.prefix(8).map(\.id)).filter { seen.insert($0).inserted }
    }

    private func person(_ hex: String) -> some View {
        let profile = nostr.profiles[hex]
        return HStack(spacing: 10) {
            AvatarView(url: profile?.pictureURL, pubkey: hex, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile?.bestName ?? String(hex.prefix(8)))
                Text(Data(hexString: hex).flatMap { Bech32.encode(hrp: "npub", data: $0) }.map { String($0.prefix(20)) + "…" } ?? "")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }

    private func send() {
        guard canSend, let to = recipient else { return }
        sending = true
        error = nil
        let text = message
        Task {
            do {
                try await DMShareHandler.send(intent, message: text, toHex: to)
                // Like Highlight: the card goes as soon as it is sent, so a
                // second tap (or the card coming back) cannot send it twice.
                sent = true
                close()
            } catch {
                self.error = error.localizedDescription
            }
            sending = false
        }
    }
}
