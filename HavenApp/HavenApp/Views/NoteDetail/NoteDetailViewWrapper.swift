import SwiftUI
import Combine

// MARK: - NoteDetailViewWrapper

struct NoteDetailViewWrapper: View {
    let noteId: String
    var onDismiss: (() -> Void)? = nil
    /// Pushed onto an existing navigation stack rather than presented as a
    /// sheet: no stack of its own and no Done button — Back closes it.
    var pushed = false
    @State private var resolvedNote: FeedNote?
    @State private var isLoading = true
    @State private var error: String?

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var configService: ConfigService
    @StateObject private var feedService = FeedService.shared
    @State private var cancellables = Set<AnyCancellable>()

    var body: some View {
        if pushed {
            content
                .onAppear { fetchNote() }
        } else {
            NavigationStack {
                content
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") {
                                if let onDismiss = onDismiss {
                                    onDismiss()
                                } else {
                                    dismiss()
                                }
                            }
                        }
                    }
            }
            .onAppear {
                fetchNote()
            }
        }
    }

    private var content: some View {
            Group {
                if let note = resolvedNote {
                    NoteDetailView(note: note)
                } else if isLoading {
                    VStack {
                        ProgressView()
                        Text("Fetching note...")
                            .foregroundColor(.secondary)
                            .padding()
                    }
                } else if let error = error {
                    VStack {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.appLargeTitle)
                        Text(error)
                            .padding()
                    }
                }
            }
    }

    private func fetchNote() {
        if let existing = feedService.findNote(id: noteId) {
            self.resolvedNote = existing
            self.isLoading = false
            return
        }

        // Build the appropriate REQ filter based on identifier type
        let filter: [String: Any]
        if noteId.hasPrefix("naddr1") {
            guard let decoded = Bech32.decode(noteId) else {
                self.isLoading = false
                self.error = "Invalid naddr identifier"
                return
            }
            // One reader for every naddr the app meets — a `nostr:` link from
            // another app lands here, a quoted naddr inside a note goes through
            // `coordinate(fromNaddrTLV:)`, and both must agree on what a payload
            // names. It also refuses a `d` tag that is not valid UTF-8 instead of
            // reading it as the empty `d` tag, which named a different event.
            guard let parts = QuoteReference.naddrParts(fromTLV: decoded.data) else {
                self.isLoading = false
                self.error = "Could not decode naddr"
                return
            }
            filter = ["kinds": [parts.kind], "authors": [parts.pubkey], "#d": [parts.dTag], "limit": 1]
        } else {
            let hexId: String
            if noteId.hasPrefix("note1") {
                hexId = Bech32.decode(noteId)?.hexString ?? noteId
            } else if noteId.hasPrefix("nevent1") {
                hexId = noteId // Simplified
            } else {
                hexId = noteId
            }
            filter = ["ids": [hexId], "limit": 1]
        }

        // The inbox too: mentions, replies, likes and zaps on this device are stored there.
        let relays = ([configService.config.nostrURL, configService.config.nostrURL + "/inbox"]
                      + configService.config.readRelays).compactMap { URL(string: $0) }
        guard !relays.isEmpty else { return }

        for url in relays {
            let client = WebSocketClient()
            client.isTemporary = true

            client.messageSubject
                .receive(on: DispatchQueue.main)
                .sink { msg in
                    self.handleNoteMessage(msg, client: client)
                }
                .store(in: &cancellables)

            client.$connectionState
                .receive(on: DispatchQueue.main)
                .sink { state in
                    if state == .connected {
                        let req = ["REQ", "load-\(UUID().uuidString.prefix(8))", filter] as [Any]
                        if let data = try? JSONSerialization.data(withJSONObject: req),
                           let str = String(data: data, encoding: .utf8) {
                            client.send(text: str)
                        }
                    }
                }
                .store(in: &cancellables)

            client.connect(url: url)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            if self.isLoading {
                self.isLoading = false
                if self.resolvedNote == nil {
                    self.error = "Could not find note"
                }
            }
        }
    }

    private func handleNoteMessage(_ msg: String, client: WebSocketClient) {
        guard let data = msg.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let type = json[0] as? String, type == "EVENT",
              let ev = json[2] as? [String: Any],
              let id = ev["id"] as? String,
              let pubkey = ev["pubkey"] as? String,
              let content = ev["content"] as? String,
              let createdAt = ev["created_at"] as? Int64,
              let kind = ev["kind"] as? Int,
              let tags = ev["tags"] as? [[String]] else { return }

        let note = FeedNote(
            id: id,
            pubkey: pubkey,
            content: content,
            createdAt: Date(timeIntervalSince1970: TimeInterval(createdAt)),
            tags: tags,
            kind: kind
        )
        
        DispatchQueue.main.async {
            self.resolvedNote = note
            self.isLoading = false
            client.disconnect()
        }
    }
}
