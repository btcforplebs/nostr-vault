import SwiftUI
import Combine

extension NoteDetailView {
    // MARK: - Expanded Thread Engagement

    /// All note IDs in the current thread (parents + focused + all replies).
    private var allThreadNoteIds: Set<String> {
        var ids = Set(dynamicParents.map(\.id))
        ids.insert(focusedNote.id)
        // BFS to collect all reply IDs
        var queue = [focusedNote.id]
        while !queue.isEmpty {
            let current = queue.removeFirst()
            let children = feedService.notes.filter { $0.parentEventId == current }
            for child in children {
                if ids.insert(child.id).inserted {
                    queue.append(child.id)
                }
            }
        }
        return ids
    }

    func fetchAllThreadEngagement() {
        let noteIds = Array(allThreadNoteIds)
        guard !noteIds.isEmpty else { return }
        isLoadingExpandedEngagement = true

        var relayURLs: [URL] = [configService.config.nostrURL].compactMap { URL(string: $0) }
        let externalStrs = configService.config.readRelays
        relayURLs.append(contentsOf: externalStrs.compactMap { URL(string: $0) })

        // One request per small batch of notes, sent one after another on
        // each relay, so every batch gets its own `limit`.
        let requests = ThreadEngagementQuery.requests(
            for: noteIds,
            subscriptionPrefix: "thread-eng-\(UUID().uuidString.prefix(6))"
        )
        let threadIds = Set(noteIds)
        let timeout = min(6.0 + 2.0 * Double(requests.count - 1), 20.0)

        for url in relayURLs {
            let client = WebSocketClient()
            client.isTemporary = true
            var nextRequest = 0

            func sendNextRequest() {
                guard nextRequest < requests.count else {
                    client.disconnect()
                    isLoadingExpandedEngagement = false
                    return
                }
                let request = requests[nextRequest]
                nextRequest += 1
                let req = ["REQ", request.subscriptionId, request.filter] as [Any]
                if let data = try? JSONSerialization.data(withJSONObject: req),
                   let str = String(data: data, encoding: .utf8) {
                    client.send(text: str)
                }
            }

            client.messageSubject
                .receive(on: DispatchQueue.main)
                .sink { msg in
                    self.handleExpandedEngagementMessage(msg, threadIds: threadIds) { subId in
                        guard nextRequest > 0, subId == requests[nextRequest - 1].subscriptionId else { return }
                        let req = ["CLOSE", subId]
                        if let data = try? JSONSerialization.data(withJSONObject: req),
                           let str = String(data: data, encoding: .utf8) {
                            client.send(text: str)
                        }
                        sendNextRequest()
                    }
                }
                .store(in: &cancellables)

            client.$connectionState
                .receive(on: DispatchQueue.main)
                .sink { state in
                    if state == .connected, nextRequest == 0 {
                        sendNextRequest()
                    }
                }
                .store(in: &cancellables)

            client.connect(url: url)

            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                client.disconnect()
                if self.isLoadingExpandedEngagement {
                    self.isLoadingExpandedEngagement = false
                }
            }
        }
    }

    private func handleExpandedEngagementMessage(_ msg: String, threadIds: Set<String>, onEOSE: (String) -> Void) {
        guard let data = msg.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let type = json[0] as? String else { return }

        if type == "EVENT", json.count >= 3,
           let ev = json[2] as? [String: Any],
           let id = ev["id"] as? String,
           let pubkey = ev["pubkey"] as? String,
           let kind = ev["kind"] as? Int,
           let tags = ev["tags"] as? [[String]] {

            // Find which thread note this engagement targets (last matching e-tag per NIP-25)
            let eTags = tags.filter { $0.count >= 2 && $0[0] == "e" }
            guard let targetNoteId = eTags.last(where: { threadIds.contains($0[1]) })?[1] else { return }

            guard let evData = try? JSONSerialization.data(withJSONObject: ev),
                  let event = try? JSONDecoder().decode(NostrEvent.self, from: evData) else { return }

            if kind == 7 {
                if !(perNoteReactions[targetNoteId]?.contains(where: { $0.id == id }) ?? false) {
                    perNoteReactions[targetNoteId, default: []].append(event)
                }
            } else if kind == 6 {
                if !(perNoteReposts[targetNoteId]?.contains(where: { $0.id == id }) ?? false) {
                    perNoteReposts[targetNoteId, default: []].append(event)
                }
            } else if kind == 9735 {
                if !(perNoteZaps[targetNoteId]?.contains(where: { $0.id == id }) ?? false),
                   let recipientPubkey = tags.first(where: { $0.count >= 2 && $0[0] == "p" })?[1] {
                    Task {
                        guard await ZapValidationService.isValidReceipt(pubkey: pubkey, recipientPubkey: recipientPubkey) else { return }
                        if !(self.perNoteZaps[targetNoteId]?.contains(where: { $0.id == id }) ?? false) {
                            self.perNoteZaps[targetNoteId, default: []].append(event)
                        }
                    }
                }
            }

            if nostrService.profiles[pubkey] == nil {
                nostrService.fetchMissingProfiles(for: [pubkey])
            }
            // For zaps, also fetch the sender profile
            if kind == 9735,
               let descJson = tags.first(where: { $0.count >= 2 && $0[0] == "description" })?[1],
               let descData = descJson.data(using: .utf8),
               let zapReq = try? JSONSerialization.jsonObject(with: descData) as? [String: Any],
               let senderPubkey = zapReq["pubkey"] as? String,
               nostrService.profiles[senderPubkey] == nil {
                nostrService.fetchMissingProfiles(for: [senderPubkey])
            }
        } else if type == "EOSE", json.count >= 2, let subId = json[1] as? String {
            onEOSE(subId)
        }
    }

    // MARK: - Per-Note Engagement Helpers

    func groupedReactionsForNote(_ noteId: String) -> [(emoji: String, count: Int)] {
        if configService.config.zapsOnlyMode { return [] }
        let reactions = (perNoteReactions[noteId] ?? []).map { (content: $0.content, pubkey: $0.pubkey, createdAt: $0.created_at) }
        return ReactionGrouping.groups(reactions).map { (emoji: $0.emoji, count: $0.count) }
    }

    func zapTotalForNote(_ noteId: String) -> (count: Int, sats: Int64) {
        let zaps = perNoteZaps[noteId] ?? []
        var totalSats: Int64 = 0
        for zap in zaps {
            totalSats += Int64(LiveChat.zapAmountSats(receiptTags: zap.tags))
        }
        return (count: zaps.count, sats: totalSats)
    }

    func repostCountForNote(_ noteId: String) -> Int {
        Set((perNoteReposts[noteId] ?? []).map(\.pubkey)).count
    }

    private func blockUser(hexPubkey: String) {
        guard let data = Bech32.hexToData(hexPubkey),
              let npub = Bech32.encode(hrp: "npub", data: data) else { return }
        configService.blockProfile(npub)
        nostrService.objectWillChange.send()
        presentationMode.wrappedValue.dismiss()
    }
    
    private func repostNote() {
        PendingPostManager.shared.startRepost(sourceNote: note, nostrService: nostrService)
    }

    private func getLightingAddress(for pubkey: String) -> String? {
        if let profile = nostrService.profiles[pubkey] {
            if let lud06 = profile.lud06, !lud06.isEmpty { return "lnurl:" + lud06 }
            if let lud16 = profile.lud16, !lud16.isEmpty { return lud16 }
            // NIP-05 resolves to /.well-known/nostr.json — a completely different endpoint
            // from the LUD-16 /.well-known/lnurlp/ path. Do NOT use NIP-05 as a lightning address.
        }
        return nil
    }
    
    private func zapNote(lud16: String, amount: Int? = nil) async {
        let amountSats = amount ?? (ConfigService.shared.config.defaultZapAmount / 1000)

        do {
            try await ZapService.shared.zapNote(
                noteId: note.id,
                notePubkey: note.pubkey,
                lud16: lud16,
                amountSats: amountSats
            )
            await MainActor.run {
                feedService.zappedEventIds[note.id] = amountSats
                feedService.saveInteractionState()
            }
            // Re-fetch engagement after a delay so the zap receipt has time to propagate
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await MainActor.run {
                fetchEngagement(for: note.id)
            }
        } catch {
            print("Zap failed: \(error.localizedDescription)")
        }
    }
}
