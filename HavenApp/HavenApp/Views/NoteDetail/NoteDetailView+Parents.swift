import SwiftUI
import Combine

extension NoteDetailView {
    // MARK: - Thread Loading

    func fetchParents() {
        // NIP-10: A reply note includes e-tags for all thread ancestors.
        // Extract ALL ancestor IDs and fetch them in a single batch request
        // instead of chasing parents one-by-one with sequential round-trips.
        // Mentions are skipped; a NIP-22 comment's `E` root is included.
        var ancestorIds: [String] = []
        for tag in ParentLookupRelays.ancestorTags(note.tags) where !ancestorIds.contains(tag[1]) {
            ancestorIds.append(tag[1])
        }

        guard !ancestorIds.isEmpty, !isLoadingParents else { return }
        isLoadingParents = true

        var relayURLs: [URL] = [configService.config.nostrURL].compactMap { URL(string: $0) }
        let externalStrs = configService.config.readRelays
        relayURLs.append(contentsOf: externalStrs.compactMap { URL(string: $0) })
        // The e-tag hint and the parent author's write relays, as Android
        // does: a parent that lives only on its author's relay never loaded.
        let known = relayURLs.map(\.absoluteString)
        let outbox = { (pk: String) in NostrService.shared.outboxRelays[pk] }
        relayURLs.append(contentsOf: ParentLookupRelays.extraRelays(
            tags: note.tags, replyToPubkey: note.replyToPubkey, known: known, outbox: outbox
        ).compactMap { URL(string: $0) })

        let subId = "thread-\(UUID().uuidString.prefix(8))"
        askRelays(relayURLs, ids: ancestorIds, subId: subId)

        // Authors whose relay list we don't have yet: fetch it, then ask
        // their relays once more if the parents still haven't come.
        let unknown = ParentLookupRelays.authors(tags: note.tags, replyToPubkey: note.replyToPubkey)
            .filter { NostrService.shared.outboxRelays[$0] == nil }
        guard !unknown.isEmpty else { return }
        feedService.requestRelayLists(for: Set(unknown))
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            guard ancestorIds.contains(where: { id in !self.parentNotes.contains { $0.id == id } }) else { return }
            let later = ParentLookupRelays.extraRelays(
                tags: self.note.tags, replyToPubkey: self.note.replyToPubkey,
                known: relayURLs.map(\.absoluteString), outbox: outbox
            ).compactMap { URL(string: $0) }
            guard !later.isEmpty else { return }
            self.isLoadingParents = true
            self.askRelays(later, ids: ancestorIds, subId: subId)
        }
    }

    private func askRelays(_ relayURLs: [URL], ids ancestorIds: [String], subId: String) {
        for url in relayURLs {
            let client = WebSocketClient()
            client.isTemporary = true

            client.messageSubject
                .receive(on: DispatchQueue.main)
                .sink { msg in
                    self.handleParentMessage(msg, client: client)
                }
                .store(in: &cancellables)

            client.$connectionState
                .receive(on: DispatchQueue.main)
                .sink { state in
                    if state == .connected {
                        // Single batch request for ALL ancestors at once
                        let filter: [String: Any] = ["ids": ancestorIds, "limit": 50]
                        let req = ["REQ", subId, filter] as [Any]
                        if let data = try? JSONSerialization.data(withJSONObject: req),
                           let str = String(data: data, encoding: .utf8) {
                            client.send(text: str)
                        }
                    }
                }
                .store(in: &cancellables)

            client.connect(url: url)

            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                client.disconnect()
                if self.isLoadingParents {
                    withAnimation(Motion.fade) {
                        self.isLoadingParents = false
                    }
                }
            }
        }
    }

    private func handleParentMessage(_ msg: String, client: WebSocketClient) {
        guard let frame = RelayFrame.parse(msg) else { return }
        let type = frame.type, json = frame.json

        if type == "EVENT", json.count >= 3,
           let ev = json[2] as? [String: Any],
           let id = ev["id"] as? String,
           let pubkey = ev["pubkey"] as? String,
           let content = ev["content"] as? String,
           let createdAt = ev["created_at"] as? Int64,
           let kind = ev["kind"] as? Int,
           let tags = ev["tags"] as? [[String]] {
            // A deleted post never comes back as a parent or a reply.
            if feedService.isDeleted(id) { return }

            let parent = FeedNote(
                id: id,
                pubkey: pubkey,
                content: content,
                createdAt: Date(timeIntervalSince1970: TimeInterval(createdAt)),
                tags: tags,
                kind: kind
            )

            if !parentNotes.contains(where: { $0.id == id }) {
                parentNotes.append(parent)
                parentNotes.sort { $0.createdAt < $1.createdAt }
            }

            // Also store in feedService so focusedNote and the replies section can resolve them
            if feedService.findNote(id: id) == nil {
                feedService.parentNotesCache[id] = parent
            }

            if nostrService.profiles[pubkey] == nil {
                nostrService.fetchMissingProfiles(for: [pubkey])
            }
        } else if type == "EOSE" {
            client.disconnect()
            withAnimation(Motion.fade) {
                isLoadingParents = false
            }
        }
    }

}
