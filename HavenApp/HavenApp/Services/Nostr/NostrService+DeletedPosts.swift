import Foundation
import Combine

/// Recently Deleted: a copy of each post this device deletes, so it can be
/// posted again. See `DeletedPost` for why un-delete makes a new post.
extension NostrService {
    /// Saves a copy of your post `id` before its delete request goes out.
    /// Looks in memory first, then asks this device's vault, which still holds
    /// the post until the kind 5 reaches it. A post found nowhere, or not
    /// signed by the active account, is not saved; the delete still goes ahead.
    func saveCopyBeforeDeleting(id: String) async {
        let owner = activeHexPubkey
        guard !owner.isEmpty else { return }
        var found = cachedSignedEvent(id: id)
        if found == nil { found = await fetchFromOwnVault(id: id) }
        guard let event = found, event.id == id, event.pubkey == owner, !event.sig.isEmpty else { return }
        DeletedPostsStore.shared.save(DeletedPost(
            id: event.id, pubkey: event.pubkey, createdAt: event.created_at, kind: event.kind,
            tags: event.tags, content: event.content, sig: event.sig, deletedAt: Date()
        ))
    }

    /// Posts the saved copy again as a new event, stamped now, then drops the
    /// copy. Returns false if it was not posted (signing failed, or the
    /// account changed so it would go out under another name).
    func undelete(_ post: DeletedPost) async -> Bool {
        guard post.pubkey == activeHexPubkey else { return false }
        let draft = post.republishDraft()
        let pow = PowPreferences.snapshot()
        guard let event = await mineAndSignEventAsync(
            kind: draft.kind, content: draft.content, tags: draft.tags,
            difficulty: pow.noteEnabled ? pow.noteDifficulty : 0
        ), event.pubkey == post.pubkey else { return false }
        postEvent(event)
        FeedService.shared.addNote(FeedNote(
            id: event.id,
            pubkey: event.pubkey,
            content: event.content,
            createdAt: Date(timeIntervalSince1970: TimeInterval(event.created_at)),
            tags: event.tags,
            kind: event.kind
        ))
        DeletedPostsStore.shared.remove(id: post.id, account: post.pubkey)
        return true
    }

    /// The full signed event, from the feed's raw-event cache or `events`.
    private func cachedSignedEvent(id: String) -> NostrEvent? {
        if let json = FeedService.shared.rawEventCache[id],
           NostrEventVerifier.isValid(json: json),
           let data = json.data(using: .utf8),
           let event = try? JSONDecoder().decode(NostrEvent.self, from: data) {
            return event
        }
        return events.first { $0.id == id }
    }

    /// One `ids` query to this device's vault (the relay root holds your own
    /// posts). nil if the relay is not up or does not answer in time.
    private func fetchFromOwnVault(id: String, timeout: TimeInterval = 3) async -> NostrEvent? {
        guard RelayProcessManager.shared.isRunning, !RelayProcessManager.shared.isBooting,
              let url = URL(string: ConfigService.shared.config.nostrURL) else { return nil }

        return await withCheckedContinuation { (continuation: CheckedContinuation<NostrEvent?, Never>) in
            let client = WebSocketClient()
            client.isTemporary = true
            var subs = Set<AnyCancellable>()
            var resumed = false
            let subId = "undel-\(UUID().uuidString.prefix(6))"

            func finish(_ event: NostrEvent?) {
                guard !resumed else { return }
                resumed = true
                client.disconnect()
                subs.removeAll()
                continuation.resume(returning: event)
            }

            client.messageSubject
                .receive(on: DispatchQueue.main)
                .sink { message in
                    guard let data = message.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
                          let type = json.first as? String else { return }
                    if type == "EVENT", let dict = json[safe: 2] as? [String: Any],
                       let raw = try? JSONSerialization.data(withJSONObject: dict),
                       let str = String(data: raw, encoding: .utf8),
                       NostrEventVerifier.isValid(json: str),
                       let event = try? JSONDecoder().decode(NostrEvent.self, from: raw),
                       event.id == id {
                        finish(event)
                    } else if type == "EOSE" || type == "CLOSED" {
                        finish(nil)
                    }
                }
                .store(in: &subs)
            client.$connectionState
                .receive(on: DispatchQueue.main)
                .sink { state in
                    guard state == .connected else { return }
                    let req = ["REQ", subId, ["ids": [id], "limit": 1]] as [Any]
                    if let data = try? JSONSerialization.data(withJSONObject: req),
                       let str = String(data: data, encoding: .utf8) {
                        client.send(text: str)
                    }
                }
                .store(in: &subs)
            client.connect(url: url)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }
}
