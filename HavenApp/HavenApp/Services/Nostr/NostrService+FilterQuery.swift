import Foundation
import Combine

extension NostrService {
    /// Every signature-checked event matching `filter` that `relays` send
    /// before each has answered EOSE or `timeout` passes, each once. Opens its
    /// own sockets, so it works before the device's relay or the feed is up
    /// (setup's referrer step runs before either). The device's own relay is
    /// skipped unless `includeLoopback` asks for it (the Vault tab reading
    /// another account's lines from it).
    func fetchEvents(filter: [String: Any], from relays: [String], timeout: TimeInterval = 6,
                     includeLoopback: Bool = false) async -> [NostrEvent] {
        let targets = relays.filter { includeLoopback || !Self.isLoopbackRelay($0) }.compactMap { URL(string: $0) }
        guard !targets.isEmpty else { return [] }

        return await withCheckedContinuation { (continuation: CheckedContinuation<[NostrEvent], Never>) in
            let lock = NSLock()
            var found: [String: NostrEvent] = [:]
            var finished = Set<Int>()
            var resumed = false
            var clients: [WebSocketClient] = []
            var subs = Set<AnyCancellable>()

            func finish() {
                lock.lock()
                guard !resumed else { lock.unlock(); return }
                resumed = true
                let events = Array(found.values)
                lock.unlock()
                DispatchQueue.main.async {
                    clients.forEach { $0.disconnect() }
                    subs.removeAll()
                }
                continuation.resume(returning: events)
            }

            DispatchQueue.main.async {
                for (index, url) in targets.enumerated() {
                    let client = WebSocketClient()
                    client.isTemporary = true
                    clients.append(client)
                    let subId = "q-\(UUID().uuidString.prefix(6))"
                    client.messageSubject
                        .sink { message in
                            guard let data = message.data(using: .utf8),
                                  let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
                                  let type = json.first as? String else { return }
                            if type == "EVENT", json[safe: 1] as? String == subId,
                               let dict = json[safe: 2] as? [String: Any],
                               let raw = try? JSONSerialization.data(withJSONObject: dict),
                               let event = try? JSONDecoder().decode(NostrEvent.self, from: raw) {
                                lock.lock()
                                let isNew = found[event.id] == nil
                                lock.unlock()
                                guard isNew, let str = String(data: raw, encoding: .utf8),
                                      NostrEventVerifier.isValid(json: str) else { return }
                                lock.lock()
                                found[event.id] = event
                                lock.unlock()
                            } else if type == "EOSE" || type == "CLOSED" {
                                lock.lock()
                                finished.insert(index)
                                let all = finished.count >= targets.count
                                lock.unlock()
                                if all { finish() }
                            }
                        }
                        .store(in: &subs)
                    client.$connectionState
                        .sink { state in
                            guard state == .connected else { return }
                            let req = ["REQ", subId, filter] as [Any]
                            if let data = try? JSONSerialization.data(withJSONObject: req),
                               let str = String(data: data, encoding: .utf8) {
                                client.send(text: str)
                            }
                        }
                        .store(in: &subs)
                    client.connect(url: url)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { finish() }
            }
        }
    }

    /// Stores fetched kind 0s the way the live feed does, so every view that
    /// reads `profiles` (avatars, names) draws them. Newer ones only.
    @MainActor
    func ingestProfiles(_ events: [NostrEvent]) {
        for event in events.filter({ $0.kind == 0 }).sorted(by: { $0.created_at < $1.created_at }) {
            let existing = profileWrites.current(event.pubkey, stored: profiles)
            if let result = ProfileRepository.parseMetadataContent(event.content, pubkey: event.pubkey,
                                                                   existingProfile: existing, createdAt: event.created_at),
               result.changed {
                queueProfileWrite(result.profile)
            }
        }
    }
}
