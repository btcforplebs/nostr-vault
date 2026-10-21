import SwiftUI
import Combine

extension NoteDetailView {
    // MARK: - Thread Loading

    func fetchParents() {
        // NIP-10: A reply note includes e-tags for all thread ancestors.
        // Extract ALL ancestor IDs and fetch them in a single batch request
        // instead of chasing parents one-by-one with sequential round-trips.
        let ancestorIds = note.tags
            .filter { $0.count >= 2 && $0[0] == "e" }
            .filter { tag in
                // Skip explicitly-marked mentions (not thread ancestors)
                if tag.count >= 4 && tag[3] == "mention" { return false }
                return true
            }
            .map { $0[1] }

        guard !ancestorIds.isEmpty, !isLoadingParents else { return }
        isLoadingParents = true

        var relayURLs: [URL] = [configService.config.nostrURL].compactMap { URL(string: $0) }
        let externalStrs = configService.config.readRelays
        relayURLs.append(contentsOf: externalStrs.compactMap { URL(string: $0) })

        let subId = "thread-\(UUID().uuidString.prefix(8))"

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
        guard let data = msg.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let type = json[0] as? String else { return }

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
