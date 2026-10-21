import Foundation
import Combine

extension DMService {
    // MARK: - Public Methods

    func startListening() {
        guard RelayProcessManager.shared.state == .running else {
            #if DEBUG
            print("⏳ Relay not running yet, deferring DM inbox connection")
            #endif
            return
        }

        guard let chatURL = chatRelayURL() else {
            #if DEBUG
            print("❌ Failed to construct chat relay URL")
            #endif
            return
        }

        // Cancel old client subscriptions before tearing down, so stale
        // clients don't fire disconnect events that produce log spam.
        connectionCancellables.removeAll()
        inboxClient?.disconnect()
        isAuthenticated = false
        authRetry.reset()

        let client = WebSocketClient()
        inboxClient = client

        client.messageSubject
            .receive(on: processingQueue)
            .sink { [weak self] message in
                self?.processMessage(message)
            }
            .store(in: &connectionCancellables)

        // dropFirst: @Published replays the current value (.disconnected) on
        // subscribe. removeDuplicates: the ping timer re-sets .disconnected on
        // a dead socket every 25 s. Between them they printed "disconnected"
        // three times per foreground and again every 25 s (71 in one report).
        var wasConnected = false
        client.$connectionState
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self = self, self.inboxClient === client else { return }
                switch state {
                case .connected:
                    // /chat requires NIP-42 AUTH — wait for the AUTH challenge
                    // before sending subscription
                    #if DEBUG
                    print("✅ DM chat relay connected, awaiting AUTH challenge...")
                    #endif
                    wasConnected = true
                    self.chatReconnectAttempt = 0
                    self.chatReconnectTask?.cancel()
                    self.chatReconnectTask = nil
                case .disconnected, .error:
                    // Only a connection that was up can be "lost".
                    #if DEBUG
                    if wasConnected { print("❌ DM chat relay disconnected") }
                    #endif
                    wasConnected = false
                    self.isAuthenticated = false
                    self.scheduleChatReconnect()
                default:
                    break
                }
            }
            .store(in: &connectionCancellables)

        #if DEBUG
        print("🔗 Connecting to DM chat relay: \(chatURL)")
        #endif
        client.connect(url: chatURL)

        // Also connect to /inbox for NIP-04 (kind 4) legacy DMs
        startNIP04Listening()
    }

    func startNIP04Listening() {
        guard let inboxURL = inboxRelayURL() else { return }

        nip04Client?.disconnect()

        let client = WebSocketClient()
        nip04Client = client

        client.messageSubject
            .receive(on: processingQueue)
            .sink { [weak self] message in
                self?.processNIP04Message(message)
            }
            .store(in: &connectionCancellables)

        client.$connectionState
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self = self, self.nip04Client === client else { return }
                switch state {
                case .connected:
                    #if DEBUG
                    print("✅ NIP-04 inbox connected")
                    #endif
                    self.inboxReconnectAttempt = 0
                    self.inboxReconnectTask?.cancel()
                    self.inboxReconnectTask = nil
                    self.sendNIP04Subscription(to: client)
                case .disconnected, .error:
                    self.scheduleInboxReconnect()
                default:
                    break
                }
            }
            .store(in: &connectionCancellables)

        #if DEBUG
        print("🔗 Connecting to NIP-04 inbox: \(inboxURL)")
        #endif
        client.connect(url: inboxURL)
    }

    private func sendNIP04Subscription(to client: WebSocketClient) {
        let ownPubkey = loadedAccountPubkey
        guard !ownPubkey.isEmpty else { return }

        // Subscribe for kind 4 events where we're tagged OR we're the author
        let filterTagged: [String: Any] = [
            "kinds": [4],
            "#p": [ownPubkey]
        ]
        let filterAuthored: [String: Any] = [
            "kinds": [4],
            "authors": [ownPubkey]
        ]

        // Gift wraps sent to this relay's /inbox — it is the owner's Haven DM
        // inbox, the first entry of the published DM relay list — are stored
        // there, not in /chat, so read them here too.
        let filterWraps: [String: Any] = [
            "kinds": [1059],
            "#p": [ownPubkey]
        ]

        let req1 = ["REQ", "nip04-in", filterTagged] as [Any]
        let req2 = ["REQ", "nip04-out", filterAuthored] as [Any]
        let req3 = ["REQ", "inbox-wraps", filterWraps] as [Any]
        if let data = try? JSONSerialization.data(withJSONObject: req3),
           let str = String(data: data, encoding: .utf8) {
            client.send(text: str)
        }

        if let data = try? JSONSerialization.data(withJSONObject: req1),
           let str = String(data: data, encoding: .utf8) {
            client.send(text: str)
        }
        if let data = try? JSONSerialization.data(withJSONObject: req2),
           let str = String(data: data, encoding: .utf8) {
            client.send(text: str)
        }
        #if DEBUG
        print("📡 Subscribed to NIP-04 DMs")
        #endif
    }

    func inboxRelayURL() -> URL? {
        let config = ConfigService.shared.config
        let port = config.relayPort
        #if os(macOS)
        return URL(string: "ws://127.0.0.1:\(port)/inbox")
        #else
        return URL(string: "wss://127.0.0.1:\(port)/inbox")
        #endif
    }

    // MARK: - Private Methods

    func sendInboxSubscription(to client: WebSocketClient) {
        let ownPubkey = loadedAccountPubkey
        guard !ownPubkey.isEmpty else { return }
        let filter: [String: Any] = [
            "kinds": [1059],
            "#p": [ownPubkey]
        ]

        let req = ["REQ", "dms", filter] as [Any]
        guard let data = try? JSONSerialization.data(withJSONObject: req),
              let str = String(data: data, encoding: .utf8) else {
            #if DEBUG
            print("❌ Failed to create subscription filter")
            #endif
            return
        }
        isLoading = true
        #if DEBUG
        print("📡 Sending DM subscription: \(str)")
        #endif
        client.send(text: str)
    }
}
