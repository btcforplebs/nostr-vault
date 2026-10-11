import Foundation
import Combine

extension DMService {
    func handleAccountSwitch() {
        let newPubkey = NostrService.shared.activeHexPubkey
        guard newPubkey != loadedAccountPubkey else {
            // Same account, just reconnect (e.g. relay port changed)
            reconnectInbox()
            return
        }

        // Increment generation to invalidate all in-flight async callbacks
        switchGeneration &+= 1

        // The new account may have signing capability the previous one lacked
        // (or vice-versa) — let the watch-only notices fire once again.
        warnedNIP04Unavailable = false
        warnedAuthUnavailable = false

        // Disconnect any in-flight external relay clients immediately
        for client in externalClients {
            client.disconnect()
        }
        externalClients.removeAll()

        // Save current account's conversations
        saveConversations()

        // Switch to new account
        loadedAccountPubkey = newPubkey
        conversations = []
        seenGiftWrapIds.removeAll()
        unreadableGiftWrapIds.removeAll()
        pendingGiftWraps.removeAll()
        clearSignerWaiting()
        injectedDmIds.removeAll()
        isAuthenticated = false
        pendingAuthChallenge = nil

        // Tear down injection clients from previous account
        disconnectInjectionClients()

        // Load new account's conversations
        loadConversations()

        reconnectInbox(force: true)
    }

    static func chatReconnectDelay(attempt: Int) -> TimeInterval {
        min(pow(2, Double(min(attempt, 6))), 60)
    }

    func scheduleChatReconnect() {
        guard chatReconnectTask == nil, RelayProcessManager.shared.state == .running else { return }
        let delay = Self.chatReconnectDelay(attempt: chatReconnectAttempt)
        chatReconnectAttempt += 1
        chatReconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.chatReconnectTask = nil
            guard RelayProcessManager.shared.state == .running,
                  self.inboxClient?.connectionState != .connected,
                  self.inboxClient?.connectionState != .connecting else { return }
            #if DEBUG
            print("🔄 DM chat relay: reconnecting (attempt \(self.chatReconnectAttempt))")
            #endif
            self.startListening()
        }
    }

    /// Brings the DM sockets back only when they actually need it.
    ///
    /// `/chat` challenges every new connection with NIP-42, so every teardown
    /// costs a kind 22242 signature. With a remote signer that is a full round
    /// trip, and one more request queued in front of whatever the person does
    /// next — and this runs on every foreground, every open of the inbox and
    /// every pull-to-refresh. So ask the live socket whether it is still there
    /// (a WebSocket ping, which never reaches the signer) and rebuild only if
    /// it is not. `force` is for an account switch, where a healthy socket
    /// still has to go: its subscription and its AUTH belong to the account we
    /// just left.
    func reconnectInbox(force: Bool = false) {
        guard !force, let chat = inboxClient,
              chat.connectionState == .connected, isAuthenticated else {
            restartInbox()
            return
        }
        chat.probeAlive { [weak self] alive in
            DispatchQueue.main.async {
                guard let self = self else { return }
                // Same socket, and it answered: keep it, and with it the AUTH
                // signature already paid for.
                guard alive, self.inboxClient === chat, self.isAuthenticated else {
                    self.restartInbox()
                    return
                }
                #if DEBUG
                print("✅ DM chat relay still live — kept (no new NIP-42 AUTH)")
                #endif
                // The legacy NIP-04 inbox needs no AUTH, so cycling it is free.
                self.restartNIP04IfNeeded()
            }
        }
    }

    private func restartInbox() {
        // Drop the old client's subscriptions first, so tearing it down does
        // not log a "disconnected" (or schedule a reconnect) of its own.
        connectionCancellables.removeAll()
        chatReconnectTask?.cancel()
        chatReconnectTask = nil
        inboxClient?.disconnect()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.startListening()
        }
    }

    func scheduleInboxReconnect() {
        guard inboxReconnectTask == nil, RelayProcessManager.shared.state == .running else { return }
        let delay = Self.chatReconnectDelay(attempt: inboxReconnectAttempt)
        inboxReconnectAttempt += 1
        inboxReconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.inboxReconnectTask = nil
            guard RelayProcessManager.shared.state == .running,
                  self.nip04Client?.connectionState != .connected,
                  self.nip04Client?.connectionState != .connecting else { return }
            #if DEBUG
            print("🔄 DM inbox relay: reconnecting (attempt \(self.inboxReconnectAttempt))")
            #endif
            self.startNIP04Listening()
        }
    }

    /// Redials the kind 4 inbox when it is the half that died, without
    /// touching the authenticated /chat socket next to it.
    private func restartNIP04IfNeeded() {
        guard let legacy = nip04Client, legacy.connectionState == .connected else {
            startNIP04Listening()
            return
        }
        legacy.probeAlive { [weak self] alive in
            guard !alive else { return }
            DispatchQueue.main.async {
                guard let self = self, self.nip04Client === legacy else { return }
                self.startNIP04Listening()
            }
        }
    }

    func chatRelayURL() -> URL? {
        let config = ConfigService.shared.config
        let port = config.relayPort
        #if os(macOS)
        return URL(string: "ws://127.0.0.1:\(port)/chat")
        #else
        return URL(string: "wss://127.0.0.1:\(port)/chat")
        #endif
    }

    func setupThrottling() {
        dmUpdateSubject
            .throttle(for: .milliseconds(250), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }
}
