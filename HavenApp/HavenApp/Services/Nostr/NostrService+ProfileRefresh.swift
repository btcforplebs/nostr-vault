import Foundation

extension NostrService {
    /// Asks the profile index relays, at most once a day per `scope` and
    /// account, for the profiles of `pubkeys` that changed since the last
    /// check (see `ProfileRefreshPlan`). Answers land through the usual kind-0
    /// handling, which keeps the newest. The check counts as done once a relay
    /// takes the request, so an offline phone tries again next time.
    func refreshChangedProfiles(_ pubkeys: [String], scope: String) {
        let owner = activeHexPubkey
        guard !owner.isEmpty, !pubkeys.isEmpty else { return }
        let key = "profileRefresh.\(scope).\(owner)"
        let lastCheck = UserDefaults.standard.object(forKey: key) as? Date
        let now = Date()
        guard ProfileRefreshPlan.isDue(lastCheck: lastCheck, now: now),
              profileRefreshesRunning.insert(key).inserted else { return }
        let filters = ProfileRefreshPlan.filters(for: pubkeys, since: ProfileRefreshPlan.since(lastCheck: lastCheck))
        let request: [Any] = ["REQ", "meta-refresh-\(UUID().uuidString.prefix(8))"] + filters
        guard let data = try? JSONSerialization.data(withJSONObject: request),
              let text = String(data: data, encoding: .utf8) else {
            profileRefreshesRunning.remove(key)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            self?.profileRefreshesRunning.remove(key)
        }

        for url in Self.profileIndexRelays.compactMap({ URL(string: $0) }) {
            let client = WebSocketClient()
            client.isTemporary = true
            let urlString = url.absoluteString
            client.messageSubject
                .receive(on: processingQueue)
                .sink { [weak self] message in
                    self?.processMessage(message, from: urlString)
                }
                .store(in: &cancellables)
            client.$connectionState
                .receive(on: DispatchQueue.main)
                .sink { state in
                    guard state == .connected else { return }
                    client.send(text: text)
                    UserDefaults.standard.set(now, forKey: key)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                        client.disconnect()
                    }
                }
                .store(in: &cancellables)
            client.connect(url: url)
            trackTemporaryClient(client)
        }
    }
}
