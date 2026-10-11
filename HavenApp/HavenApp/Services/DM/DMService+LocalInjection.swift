import Foundation
import Combine

extension DMService {
    /// Injects an externally-fetched DM event into the local relay so it persists
    /// in the relay DB and is available on other devices via the Go relay's sync.
    func injectExternalDmIntoLocalRelay(_ eventData: [String: Any], eventId: String, kind: Int) {
        // Dedup: skip events we've already injected this session
        guard !injectedDmIds.contains(eventId) else { return }
        injectedDmIds.insert(eventId)
        if injectedDmIds.count > maxInjectedDmIds {
            injectedDmIds.removeAll(keepingCapacity: true)
        }

        if kind == 1059 {
            injectViaChatClient(eventData)
        } else {
            injectViaInboxClient(eventData)
        }
    }

    func sendEventToClient(_ client: WebSocketClient, _ eventData: [String: Any]) {
        let msg = ["EVENT", eventData] as [Any]
        if let data = try? JSONSerialization.data(withJSONObject: msg),
           let str = String(data: data, encoding: .utf8) {
            client.send(text: str)
        }
    }

    func injectViaChatClient(_ eventData: [String: Any]) {
        if let client = chatInjectionClient, client.connectionState == .connected {
            sendEventToClient(client, eventData)
            return
        }

        pendingChatInjections.append(eventData)

        // Already connecting, just queue
        if chatInjectionClient != nil { return }

        guard let url = chatRelayURL() else { return }
        let client = WebSocketClient()
        client.isTemporary = true
        chatInjectionClient = client

        client.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self = self else { return }
                if state == .connected {
                    for pending in self.pendingChatInjections {
                        self.sendEventToClient(client, pending)
                    }
                    self.pendingChatInjections.removeAll()
                }
            }
            .store(in: &cancellables)

        client.connect(url: url)
    }

    private func injectViaInboxClient(_ eventData: [String: Any]) {
        if let client = inboxInjectionClient, client.connectionState == .connected {
            sendEventToClient(client, eventData)
            return
        }

        pendingInboxInjections.append(eventData)

        // Already connecting, just queue
        if inboxInjectionClient != nil { return }

        guard let url = inboxRelayURL() else { return }
        let client = WebSocketClient()
        client.isTemporary = true
        inboxInjectionClient = client

        client.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self = self else { return }
                if state == .connected {
                    for pending in self.pendingInboxInjections {
                        self.sendEventToClient(client, pending)
                    }
                    self.pendingInboxInjections.removeAll()
                }
            }
            .store(in: &cancellables)

        client.connect(url: url)
    }

    /// Tears down injection clients after external fetch completes.
    func disconnectInjectionClients() {
        // Give a brief window for any final writes to flush
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.chatInjectionClient?.disconnect()
            self?.chatInjectionClient = nil
            self?.inboxInjectionClient?.disconnect()
            self?.inboxInjectionClient = nil
            self?.pendingChatInjections.removeAll()
            self?.pendingInboxInjections.removeAll()
        }
    }
}
