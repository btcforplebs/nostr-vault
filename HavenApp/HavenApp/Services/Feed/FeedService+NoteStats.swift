import Foundation
import Combine
import SwiftUI

extension FeedService {
    // MARK: - Per-Note Stats Fetch (NoteDetailView)

    /// Fetches accurate repost / reaction / zap counts for a single note
    /// by querying all configured relays in parallel. Results are deduped by event
    /// ID so counts are never inflated when the same event arrives from multiple
    /// relays. Writes the final tally to `noteStats[noteId]` on the main thread.
    func fetchNoteStats(for noteId: String) {
        // Prefer local relay; only fall back to one external relay to cap data use.
        var allURLs: [URL] = []
        if let local = localRelayURL {
            allURLs.append(local)
        }
        if let inbox = localInboxURL {
            allURLs.append(inbox)
        }
        if allURLs.isEmpty, let first = externalRelayURLs.first {
            allURLs.append(first)
        }
        guard !allURLs.isEmpty else { return }

        // Shared mutable state — all mutations happen on the main thread via
        // DispatchQueue.main.async so no locks are needed.
        var seenEventIds = Set<String>()
        var reposts  = 0
        var reactions = 0
        var zaps     = 0
        var eoseReceived = 0
        // Each relay sends EOSE for each of the 3 subscriptions
        let expectedEOSE = allURLs.count * 3
        var finished = false
        var tempClients: [WebSocketClient] = []

        let finish: () -> Void = { [weak self] in
            guard let self = self, !finished else { return }
            finished = true
            tempClients.forEach { $0.disconnect() }
            var stats = self.noteStats[noteId] ?? NoteStats()
            stats.reposts   = reposts
            stats.reactions = reactions
            stats.zaps      = zaps
            self.noteStats[noteId] = stats
        }

        // Safety timeout: finalize after 8 seconds regardless.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { finish() }

        let subPrefix = UUID().uuidString.prefix(6)

        for (i, url) in allURLs.enumerated() {
            let client = WebSocketClient()
            client.isTemporary = true
            tempClients.append(client)

            client.messageSubject
                .receive(on: DispatchQueue.main)
                .sink { msg in
                    guard !finished,
                          let data = msg.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
                          let type = json[0] as? String else { return }

                    if type == "EOSE" {
                        eoseReceived += 1
                        if eoseReceived >= expectedEOSE { finish() }
                        return
                    }

                    guard type == "EVENT", json.count >= 3,
                          let ev   = json[2] as? [String: Any],
                          let evId = ev["id"] as? String,
                          let kind = ev["kind"] as? Int,
                          !seenEventIds.contains(evId) else { return }

                    seenEventIds.insert(evId)

                    switch kind {
                    case 6:    reposts   += 1
                    case 7:    reactions += 1
                    case 9735: zaps      += 1
                    default:   break
                    }
                }
                .store(in: &cancellables)

            client.$connectionState
                .receive(on: DispatchQueue.main)
                .sink { state in
                    guard state == .connected, !finished else { return }
                    let p = "\(subPrefix)-\(i)"
                    let filters: [[String: Any]] = [
                        ["kinds": [6],    "#e": [noteId], "limit": 100],
                        ["kinds": [7],    "#e": [noteId], "limit": 100],
                        ["kinds": [9735], "#e": [noteId], "limit": 100],
                    ]
                    for (fi, filter) in filters.enumerated() {
                        let req = ["REQ", "\(p)-\(fi)", filter] as [Any]
                        if let reqData = try? JSONSerialization.data(withJSONObject: req),
                           let reqStr  = String(data: reqData, encoding: .utf8) {
                            client.send(text: reqStr)
                        }
                    }
                }
                .store(in: &cancellables)

            client.connect(url: url)
        }
    }
}
