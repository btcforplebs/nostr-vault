import Foundation
import Combine
import SilentPaymentsKit

// MARK: - Models

struct DMMessage: Identifiable, Codable {
    let id: String
    let senderPubkey: String
    let content: String
    let timestamp: Date
    let isFromMe: Bool
    var isNIP04: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, senderPubkey, content, timestamp, isFromMe, isNIP04
    }

    init(id: String, senderPubkey: String, content: String, timestamp: Date, isFromMe: Bool, isNIP04: Bool = false) {
        self.id = id
        self.senderPubkey = senderPubkey
        self.content = content
        self.timestamp = timestamp
        self.isFromMe = isFromMe
        self.isNIP04 = isNIP04
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        senderPubkey = try container.decode(String.self, forKey: .senderPubkey)
        content = try container.decode(String.self, forKey: .content)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        isFromMe = try container.decode(Bool.self, forKey: .isFromMe)
        isNIP04 = try container.decodeIfPresent(Bool.self, forKey: .isNIP04) ?? false
    }
}

struct DMConversation: Identifiable, Codable {
    let id: String  // counterparty hex pubkey
    var messages: [DMMessage]
    var unreadCount: Int

    var lastMessage: DMMessage? {
        messages.last
    }

    var hasNIP04Messages: Bool {
        messages.contains(where: { $0.isNIP04 })
    }

    enum CodingKeys: String, CodingKey {
        case id, messages, unreadCount
    }
}

// MARK: - DMService

@MainActor
class DMService: ObservableObject {
    static let shared = DMService()

    @Published var conversations: [DMConversation] = []
    @Published var isLoading: Bool = false

    private var inboxClient: WebSocketClient?       // /chat (NIP-17 gift wraps)
    private var nip04Client: WebSocketClient?        // /inbox (NIP-04 legacy DMs)
    private var cancellables = Set<AnyCancellable>()
    private var seenGiftWrapIds = Set<String>()
    private var dmUpdateSubject = PassthroughSubject<Void, Never>()
    private let processingQueue = DispatchQueue(label: "com.haven.dm-processing", qos: .userInitiated)
    private var pendingAuthChallenge: String?
    private var isAuthenticated = false

    private init() {
        setupThrottling()
        loadConversations()

        // React to config changes (account switching)
        ConfigService.shared.$config
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.reconnectInbox()
            }
            .store(in: &cancellables)

        // Auto-connect when relay becomes available
        RelayProcessManager.shared.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self = self else { return }
                if state == .running && self.inboxClient == nil {
                    self.startListening()
                } else if state == .idle {
                    self.inboxClient?.disconnect()
                    self.inboxClient = nil
                    self.nip04Client?.disconnect()
                    self.nip04Client = nil
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Public Methods

    func startListening() {
        guard RelayProcessManager.shared.state == .running else {
            print("⏳ Relay not running yet, deferring DM inbox connection")
            return
        }

        guard let chatURL = chatRelayURL() else {
            print("❌ Failed to construct chat relay URL")
            return
        }

        // Disconnect any existing client and reset auth state
        inboxClient?.disconnect()
        isAuthenticated = false
        pendingAuthChallenge = nil

        let client = WebSocketClient()
        inboxClient = client

        client.messageSubject
            .receive(on: processingQueue)
            .sink { [weak self] message in
                self?.processMessage(message)
            }
            .store(in: &cancellables)

        client.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                switch state {
                case .connected:
                    // /chat requires NIP-42 AUTH — wait for the AUTH challenge
                    // before sending subscription
                    print("✅ DM chat relay connected, awaiting AUTH challenge...")
                case .disconnected, .error:
                    print("❌ DM chat relay disconnected")
                    self?.isAuthenticated = false
                default:
                    break
                }
            }
            .store(in: &cancellables)

        print("🔗 Connecting to DM chat relay: \(chatURL)")
        client.connect(url: chatURL)

        // Also connect to /inbox for NIP-04 (kind 4) legacy DMs
        startNIP04Listening()
    }

    private func startNIP04Listening() {
        guard let inboxURL = inboxRelayURL() else { return }

        nip04Client?.disconnect()

        let client = WebSocketClient()
        nip04Client = client

        client.messageSubject
            .receive(on: processingQueue)
            .sink { [weak self] message in
                self?.processNIP04Message(message)
            }
            .store(in: &cancellables)

        client.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self = self else { return }
                if state == .connected {
                    print("✅ NIP-04 inbox connected")
                    self.sendNIP04Subscription(to: client)
                }
            }
            .store(in: &cancellables)

        print("🔗 Connecting to NIP-04 inbox: \(inboxURL)")
        client.connect(url: inboxURL)
    }

    private func sendNIP04Subscription(to client: WebSocketClient) {
        let ownPubkey = NostrService.shared.activeHexPubkey

        // Subscribe for kind 4 events where we're tagged OR we're the author
        let filterTagged: [String: Any] = [
            "kinds": [4],
            "#p": [ownPubkey]
        ]
        let filterAuthored: [String: Any] = [
            "kinds": [4],
            "authors": [ownPubkey]
        ]

        let req1 = ["REQ", "nip04-in", filterTagged] as [Any]
        let req2 = ["REQ", "nip04-out", filterAuthored] as [Any]

        if let data = try? JSONSerialization.data(withJSONObject: req1),
           let str = String(data: data, encoding: .utf8) {
            client.send(text: str)
        }
        if let data = try? JSONSerialization.data(withJSONObject: req2),
           let str = String(data: data, encoding: .utf8) {
            client.send(text: str)
        }
        print("📡 Subscribed to NIP-04 DMs")
    }

    private func inboxRelayURL() -> URL? {
        let config = ConfigService.shared.config
        let port = config.relayPort
        return URL(string: "wss://127.0.0.1:\(port)/inbox")
    }

    func sendDM(content: String, to recipientHexPubkey: String, useNIP04: Bool = false) async throws {
        if useNIP04 {
            try await sendNIP04DM(content: content, to: recipientHexPubkey)
        } else {
            try await sendNIP17DM(content: content, to: recipientHexPubkey)
        }
    }

    /// Send a NIP-17 encrypted DM (default, recommended)
    private func sendNIP17DM(content: String, to recipientHexPubkey: String) async throws {
        let config = ConfigService.shared.config
        let ownHexPubkey = NostrService.shared.activeHexPubkey

        // Get sender's private key
        let senderPrivkey: String
        if !config.ownerNcryptsec.isEmpty {
            guard let password = NIP49Service.getPasswordFromKeychain() else {
                throw NSError(domain: "DMService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Password required for encrypted key"])
            }
            senderPrivkey = try config.getDecryptedHexKey(password: password)
        } else {
            guard let key = config.ownerHexKey, !key.isEmpty else {
                throw NSError(domain: "DMService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Sender private key not available"])
            }
            senderPrivkey = key
        }

        // Create gift wrap
        let giftWrap = try NIP17Service.createGiftWrap(
            content: content,
            recipientHexPubkey: recipientHexPubkey,
            senderHexPrivkey: senderPrivkey,
            senderHexPubkey: ownHexPubkey
        )

        // Publish to local inbox
        await publishToInbox(giftWrap)

        // Publish to recipient's DM relays (kind 10050) or fallback to read relays (kind 10002)
        let relays = await fetchRecipientDMRelays(recipientHexPubkey)
        for relayURL in relays {
            await publishToRelay(giftWrap, url: relayURL)
        }

        // Create a copy for self (wrap with own pubkey)
        let selfGiftWrap = try NIP17Service.createGiftWrap(
            content: content,
            recipientHexPubkey: ownHexPubkey,
            senderHexPrivkey: senderPrivkey,
            senderHexPubkey: ownHexPubkey
        )
        await publishToInbox(selfGiftWrap)

        // Add message to conversation optimistically
        let message = DMMessage(
            id: giftWrap.id,
            senderPubkey: ownHexPubkey,
            content: content,
            timestamp: Date(),
            isFromMe: true
        )

        if let idx = conversations.firstIndex(where: { $0.id == recipientHexPubkey }) {
            conversations[idx].messages.append(message)
        } else {
            let conversation = DMConversation(
                id: recipientHexPubkey,
                messages: [message],
                unreadCount: 0
            )
            conversations.append(conversation)
        }

        sortConversations()
        saveConversations()
    }

    /// Send a NIP-04 legacy DM (for compatibility with older clients)
    private func sendNIP04DM(content: String, to recipientHexPubkey: String) async throws {
        let config = ConfigService.shared.config
        let ownHexPubkey = NostrService.shared.activeHexPubkey

        // Get sender's private key
        let senderPrivkey: String
        if !config.ownerNcryptsec.isEmpty {
            guard let password = NIP49Service.getPasswordFromKeychain() else {
                throw NSError(domain: "DMService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Password required for encrypted key"])
            }
            senderPrivkey = try config.getDecryptedHexKey(password: password)
        } else {
            guard let key = config.ownerHexKey, !key.isEmpty else {
                throw NSError(domain: "DMService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Sender private key not available"])
            }
            senderPrivkey = key
        }

        // Encrypt content using NIP-04
        let encryptedContent = try NIP04Service.encrypt(
            plaintext: content,
            remotePubkey: recipientHexPubkey,
            localPrivkey: senderPrivkey
        )

        // Create kind 4 event
        let tags: [[String]] = [["p", recipientHexPubkey]]
        guard let event = NostrService.shared.signEvent(kind: 4, content: encryptedContent, tags: tags) else {
            throw NSError(domain: "DMService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to sign NIP-04 event"])
        }

        // Publish to local inbox
        if let inboxURL = inboxRelayURL()?.absoluteString {
            await publishToRelay(event, url: inboxURL)
        }

        // Publish to recipient's relays
        let relays = await fetchRecipientDMRelays(recipientHexPubkey)
        for relayURL in relays {
            await publishToRelay(event, url: relayURL)
        }

        // Add message to conversation optimistically
        let message = DMMessage(
            id: event.id,
            senderPubkey: ownHexPubkey,
            content: content,
            timestamp: Date(),
            isFromMe: true,
            isNIP04: true
        )

        if let idx = conversations.firstIndex(where: { $0.id == recipientHexPubkey }) {
            conversations[idx].messages.append(message)
        } else {
            let conversation = DMConversation(
                id: recipientHexPubkey,
                messages: [message],
                unreadCount: 0
            )
            conversations.append(conversation)
        }

        sortConversations()
        saveConversations()
    }

    func markRead(conversationWith pubkey: String) {
        guard let idx = conversations.firstIndex(where: { $0.id == pubkey }) else { return }
        conversations[idx].unreadCount = 0
        saveConversations()
    }

    func refresh() {
        // Reconnect to the local chat relay
        reconnectInbox()
        // Also fetch from external relays
        fetchFromExternalRelays()
    }

    /// Fetch DMs from the user's known external relays (seed relays / blastr relays)
    /// to catch any gift wraps not yet imported by the Go relay.
    func fetchFromExternalRelays() {
        let ownPubkey = NostrService.shared.activeHexPubkey
        guard !ownPubkey.isEmpty else { return }

        var relays = ConfigService.shared.config.blastrRelays
        if relays.isEmpty {
            relays = ["wss://relay.damus.io", "wss://relay.primal.net", "wss://nos.lol"]
        }

        print("🌐 Fetching DMs from \(relays.count) external relays...")

        for urlStr in relays {
            guard let url = URL(string: urlStr) else { continue }

            let client = WebSocketClient()
            client.isTemporary = true

            client.messageSubject
                .receive(on: processingQueue)
                .sink { [weak self] message in
                    self?.processExternalMessage(message)
                }
                .store(in: &cancellables)

            client.$connectionState
                .receive(on: DispatchQueue.main)
                .sink { [weak client] state in
                    guard let client = client else { return }
                    if state == .connected {
                        // NIP-17 gift wraps
                        let nip17Filter: [String: Any] = [
                            "kinds": [1059],
                            "#p": [ownPubkey],
                            "limit": 100
                        ]
                        let req1 = ["REQ", "ext-nip17-\(UUID().uuidString.prefix(6))", nip17Filter] as [Any]
                        if let data = try? JSONSerialization.data(withJSONObject: req1),
                           let str = String(data: data, encoding: .utf8) {
                            client.send(text: str)
                        }

                        // NIP-04 legacy DMs (received)
                        let nip04FilterReceived: [String: Any] = [
                            "kinds": [4],
                            "#p": [ownPubkey],
                            "limit": 100
                        ]
                        let req2 = ["REQ", "ext-nip04-in-\(UUID().uuidString.prefix(6))", nip04FilterReceived] as [Any]
                        if let data = try? JSONSerialization.data(withJSONObject: req2),
                           let str = String(data: data, encoding: .utf8) {
                            client.send(text: str)
                        }

                        // NIP-04 legacy DMs (sent)
                        let nip04FilterSent: [String: Any] = [
                            "kinds": [4],
                            "authors": [ownPubkey],
                            "limit": 100
                        ]
                        let req3 = ["REQ", "ext-nip04-out-\(UUID().uuidString.prefix(6))", nip04FilterSent] as [Any]
                        if let data = try? JSONSerialization.data(withJSONObject: req3),
                           let str = String(data: data, encoding: .utf8) {
                            client.send(text: str)
                        }

                        // Disconnect after timeout
                        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                            client.disconnect()
                        }
                    }
                }
                .store(in: &cancellables)

            client.connect(url: url)
        }
    }

    /// Handles messages from external relay fetch (both NIP-17 and NIP-04)
    private func processExternalMessage(_ message: String) {
        guard let data = message.data(using: .utf8) else { return }

        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [Any],
                  json.count >= 2,
                  let type = json[0] as? String else {
                return
            }

            if type == "EVENT",
               let eventData = json[safe: 2] as? [String: Any],
               let eventJSON = try? JSONSerialization.data(withJSONObject: eventData),
               let event = try? JSONDecoder().decode(NostrEvent.self, from: eventJSON) {
                DispatchQueue.main.async {
                    if event.kind == 1059 {
                        self.handleIncomingGiftWrap(event)
                    } else if event.kind == 4 {
                        self.handleIncomingNIP04(event)
                    }
                }
            }
        } catch {
            print("❌ Failed to process external message: \(error)")
        }
    }

    // MARK: - Private Methods

    private func sendInboxSubscription(to client: WebSocketClient) {
        let ownPubkey = NostrService.shared.activeHexPubkey
        let filter: [String: Any] = [
            "kinds": [1059],
            "#p": [ownPubkey]
        ]

        let req = ["REQ", "dms", filter] as [Any]
        guard let data = try? JSONSerialization.data(withJSONObject: req),
              let str = String(data: data, encoding: .utf8) else {
            print("❌ Failed to create subscription filter")
            return
        }
        isLoading = true
        print("📡 Sending DM subscription: \(str)")
        client.send(text: str)
    }

    private func processMessage(_ message: String) {
        guard let data = message.data(using: .utf8) else { return }

        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [Any],
                  json.count >= 2,
                  let type = json[0] as? String else {
                return
            }

            switch type {
            case "AUTH":
                // NIP-42: Relay sent AUTH challenge
                if let challenge = json[safe: 1] as? String {
                    print("🔐 Received AUTH challenge from chat relay")
                    DispatchQueue.main.async {
                        self.handleAuthChallenge(challenge)
                    }
                }
            case "OK":
                // Response to our AUTH event
                if let eventId = json[safe: 1] as? String,
                   let success = json[safe: 2] as? Bool {
                    DispatchQueue.main.async {
                        if success {
                            print("✅ AUTH successful, subscribing to DMs...")
                            let wasAuthenticated = self.isAuthenticated
                            self.isAuthenticated = true
                            if let client = self.inboxClient {
                                self.sendInboxSubscription(to: client)
                            }
                            // On first auth, also fetch from external relays for history
                            if !wasAuthenticated {
                                self.fetchFromExternalRelays()
                            }
                        } else {
                            let reason = json[safe: 3] as? String ?? "unknown"
                            print("❌ AUTH failed for \(eventId.prefix(8)): \(reason)")
                        }
                    }
                }
            case "EVENT":
                if let eventData = json[safe: 2] as? [String: Any],
                   let eventJSON = try? JSONSerialization.data(withJSONObject: eventData),
                   let event = try? JSONDecoder().decode(NostrEvent.self, from: eventJSON) {
                    DispatchQueue.main.async {
                        self.handleIncomingGiftWrap(event)
                    }
                }
            case "EOSE":
                DispatchQueue.main.async {
                    self.isLoading = false
                    print("📭 Finished loading stored DMs")
                }
            default:
                break
            }
        } catch {
            print("❌ Failed to process DM message: \(error)")
        }
    }

    private func handleAuthChallenge(_ challenge: String) {
        guard let client = inboxClient,
              let relayURL = chatRelayURL()?.absoluteString else { return }

        // Sign a NIP-42 AUTH event (kind 22242)
        let tags: [[String]] = [
            ["relay", relayURL],
            ["challenge", challenge]
        ]

        guard let authEvent = NostrService.shared.signEvent(kind: 22242, content: "", tags: tags) else {
            print("❌ Failed to sign NIP-42 AUTH event")
            return
        }

        // Send ["AUTH", <signed_event>]
        let eventDict = eventToDict(authEvent)
        let msg = ["AUTH", eventDict] as [Any]
        if let data = try? JSONSerialization.data(withJSONObject: msg),
           let str = String(data: data, encoding: .utf8) {
            print("🔐 Sending AUTH response...")
            client.send(text: str)
        }
    }

    // MARK: - NIP-04 Processing

    private func processNIP04Message(_ message: String) {
        guard let data = message.data(using: .utf8) else { return }

        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [Any],
                  json.count >= 2,
                  let type = json[0] as? String else {
                return
            }

            switch type {
            case "EVENT":
                if let eventData = json[safe: 2] as? [String: Any],
                   let eventJSON = try? JSONSerialization.data(withJSONObject: eventData),
                   let event = try? JSONDecoder().decode(NostrEvent.self, from: eventJSON) {
                    DispatchQueue.main.async {
                        self.handleIncomingNIP04(event)
                    }
                }
            default:
                break
            }
        } catch {
            print("❌ Failed to process NIP-04 message: \(error)")
        }
    }

    private func handleIncomingNIP04(_ event: NostrEvent) {
        guard event.kind == 4 else { return }
        guard !seenGiftWrapIds.contains(event.id) else { return }

        seenGiftWrapIds.insert(event.id)

        do {
            let config = ConfigService.shared.config
            let ownPrivkey: String

            if !config.ownerNcryptsec.isEmpty {
                guard let password = NIP49Service.getPasswordFromKeychain() else {
                    print("❌ Password required for encrypted key")
                    return
                }
                ownPrivkey = try config.getDecryptedHexKey(password: password)
            } else {
                guard let key = config.ownerHexKey, !key.isEmpty else {
                    print("❌ Private key not available for NIP-04 decryption")
                    return
                }
                ownPrivkey = key
            }

            let ownPubkey = NostrService.shared.activeHexPubkey
            let isFromMe = event.pubkey == ownPubkey

            // Determine counterparty
            let counterpartyPubkey: String
            if isFromMe {
                // I sent this — counterparty is in the "p" tag
                counterpartyPubkey = event.tags.first(where: { $0.count >= 2 && $0[0] == "p" })?[1] ?? ""
            } else {
                // Someone sent to me — counterparty is the event author
                counterpartyPubkey = event.pubkey
            }

            guard !counterpartyPubkey.isEmpty else { return }

            // Decrypt using NIP-04
            let plaintext = try NIP04Service.decrypt(
                ciphertext: event.content,
                remotePubkey: counterpartyPubkey,
                localPrivkey: ownPrivkey
            )

            let message = DMMessage(
                id: event.id,
                senderPubkey: event.pubkey,
                content: plaintext,
                timestamp: Date(timeIntervalSince1970: TimeInterval(event.created_at)),
                isFromMe: isFromMe,
                isNIP04: true
            )

            if let idx = conversations.firstIndex(where: { $0.id == counterpartyPubkey }) {
                guard !conversations[idx].messages.contains(where: { $0.id == event.id }) else { return }
                conversations[idx].messages.append(message)
                conversations[idx].messages.sort { $0.timestamp < $1.timestamp }
                if !isFromMe {
                    conversations[idx].unreadCount += 1
                }
            } else {
                let conversation = DMConversation(
                    id: counterpartyPubkey,
                    messages: [message],
                    unreadCount: isFromMe ? 0 : 1
                )
                conversations.append(conversation)
            }

            sortConversations()
            dmUpdateSubject.send()
            saveConversations()
        } catch {
            print("❌ Failed to decrypt NIP-04 DM: \(error)")
        }
    }

    // MARK: - NIP-17 Processing

    private func handleIncomingGiftWrap(_ event: NostrEvent) {
        guard event.kind == 1059 else { return }
        guard !seenGiftWrapIds.contains(event.id) else { return }

        seenGiftWrapIds.insert(event.id)

        do {
            let config = ConfigService.shared.config
            let recipientPrivkey: String

            if !config.ownerNcryptsec.isEmpty {
                guard let password = NIP49Service.getPasswordFromKeychain() else {
                    print("❌ Password required for encrypted key")
                    return
                }
                recipientPrivkey = try config.getDecryptedHexKey(password: password)
            } else {
                guard let key = config.ownerHexKey, !key.isEmpty else {
                    print("❌ Recipient private key not available")
                    return
                }
                recipientPrivkey = key
            }

            let (senderPubkey, content, timestamp) = try NIP17Service.unwrapGiftWrap(event, recipientPrivkey: recipientPrivkey)

            // Check if this is a Silent Payment notification (JSON with txid + tweak)
            if let contentData = content.data(using: .utf8),
               let spNotif = try? JSONDecoder().decode(SilentPaymentNotification.self, from: contentData),
               !spNotif.txid.isEmpty, !spNotif.tweak.isEmpty, spNotif.txid.count == 64 {
                Task { @MainActor in
                    SPScanService.shared.handleNotification(spNotif, from: senderPubkey, at: timestamp, eventId: event.id)
                }
                return
            }

            let ownPubkey = NostrService.shared.activeHexPubkey
            let isFromMe = senderPubkey == ownPubkey

            // Determine counterparty (the other person in the conversation)
            let counterpartyPubkey = if isFromMe {
                event.tags.first(where: { $0.count >= 2 && $0[0] == "p" })?[1] ?? senderPubkey
            } else {
                senderPubkey
            }

            let message = DMMessage(
                id: event.id,
                senderPubkey: senderPubkey,
                content: content,
                timestamp: timestamp,
                isFromMe: isFromMe
            )

            print("📨 Received DM from \(senderPubkey.prefix(8)): \(content.prefix(50))")

            if let idx = conversations.firstIndex(where: { $0.id == counterpartyPubkey }) {
                // Skip if this message ID already exists in the conversation
                guard !conversations[idx].messages.contains(where: { $0.id == event.id }) else { return }
                conversations[idx].messages.append(message)
                conversations[idx].messages.sort { $0.timestamp < $1.timestamp }
                if !isFromMe {
                    conversations[idx].unreadCount += 1
                }
            } else {
                let conversation = DMConversation(
                    id: counterpartyPubkey,
                    messages: [message],
                    unreadCount: isFromMe ? 0 : 1
                )
                conversations.append(conversation)
            }

            sortConversations()
            dmUpdateSubject.send()
            saveConversations()
        } catch {
            print("❌ Failed to unwrap gift wrap: \(error)")
        }
    }

    private func reconnectInbox() {
        inboxClient?.disconnect()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.startListening()
        }
    }

    private func chatRelayURL() -> URL? {
        let config = ConfigService.shared.config
        let port = config.relayPort
        return URL(string: "wss://127.0.0.1:\(port)/chat")
    }

    private func fetchRecipientDMRelays(_ pubkey: String) async -> [String] {
        // NIP-17: Check kind 10050 (DM relay preferences) first
        if let dmRelays = NostrService.shared.dmRelayLists[pubkey], !dmRelays.isEmpty {
            print("📋 Using NIP-17 DM relays for \(pubkey.prefix(8)): \(dmRelays)")
            return dmRelays
        }

        // Fallback to kind 10002 (general read relays)
        if let readRelays = NostrService.shared.relayLists[pubkey], !readRelays.isEmpty {
            print("📋 Using kind 10002 relay list for \(pubkey.prefix(8)): \(readRelays)")
            return readRelays
        }

        // Trigger a fetch and wait briefly for results
        NostrService.shared.fetchRelayList(for: pubkey)

        // Wait up to 4 seconds for the relay lists to populate
        for _ in 0..<8 {
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s

            // Check kind 10050 first
            if let dmRelays = NostrService.shared.dmRelayLists[pubkey], !dmRelays.isEmpty {
                print("📋 Fetched NIP-17 DM relays for \(pubkey.prefix(8)): \(dmRelays)")
                return dmRelays
            }

            // Then check kind 10002
            if let readRelays = NostrService.shared.relayLists[pubkey], !readRelays.isEmpty {
                print("📋 Fetched kind 10002 relay list for \(pubkey.prefix(8)): \(readRelays)")
                return readRelays
            }
        }

        // Fallback: use common relays where most users have inbox
        let fallbackRelays = ConfigService.shared.config.blastrRelays.isEmpty
            ? ["wss://relay.damus.io", "wss://relay.primal.net", "wss://nos.lol"]
            : ConfigService.shared.config.blastrRelays
        print("⚠️ No relay list for \(pubkey.prefix(8)), using fallback relays")
        return fallbackRelays
    }

    private func publishToInbox(_ event: NostrEvent) async {
        guard let chatURL = chatRelayURL() else { return }
        await publishToRelay(event, url: chatURL.absoluteString)
    }

    private func eventToDict(_ event: NostrEvent) -> [String: Any] {
        return [
            "id": event.id,
            "pubkey": event.pubkey,
            "created_at": event.created_at,
            "kind": event.kind,
            "tags": event.tags,
            "content": event.content,
            "sig": event.sig
        ]
    }

    private func publishToRelay(_ event: NostrEvent, url: String) async {
        guard let urlObj = URL(string: url) else { return }

        let client = WebSocketClient()
        client.isTemporary = true

        let eventDict = eventToDict(event)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var resumed = false

            let sub = client.$connectionState
                .receive(on: DispatchQueue.main)
                .sink { state in
                    if state == .connected && !resumed {
                        resumed = true

                        let msg = ["EVENT", eventDict] as [Any]
                        if let data = try? JSONSerialization.data(withJSONObject: msg),
                           let str = String(data: data, encoding: .utf8) {
                            print("📤 Publishing DM to \(url)")
                            client.send(text: str)
                        }

                        // Give the relay a moment to process, then disconnect
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            client.disconnect()
                            continuation.resume()
                        }
                    } else if case .error = state, !resumed {
                        resumed = true
                        print("❌ Failed to connect to \(url)")
                        continuation.resume()
                    }
                }

            // Retain the subscription
            self.cancellables.insert(sub)

            // Timeout: resume after 5s if nothing happened
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                if !resumed {
                    resumed = true
                    client.disconnect()
                    continuation.resume()
                }
            }

            client.connect(url: urlObj)
        }
    }

    private func setupThrottling() {
        dmUpdateSubject
            .throttle(for: .milliseconds(250), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    private func sortConversations() {
        conversations.sort { ($0.lastMessage?.timestamp ?? .distantPast) > ($1.lastMessage?.timestamp ?? .distantPast) }
    }

    private func loadConversations() {
        let fileURL = cacheFileURL()
        guard let data = try? Data(contentsOf: fileURL) else { return }
        conversations = (try? JSONDecoder().decode([DMConversation].self, from: data)) ?? []

        // Seed seenGiftWrapIds from cached messages to prevent duplicates on reconnect
        for conversation in conversations {
            for message in conversation.messages {
                seenGiftWrapIds.insert(message.id)
            }
        }
    }

    private func saveConversations() {
        let fileURL = cacheFileURL()
        guard let data = try? JSONEncoder().encode(conversations) else { return }
        try? data.write(to: fileURL)
    }

    private func cacheFileURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let havenDir = appSupport.appendingPathComponent("Haven", isDirectory: true)
        try? FileManager.default.createDirectory(at: havenDir, withIntermediateDirectories: true)
        return havenDir.appendingPathComponent("dm_cache.json")
    }
}

// MARK: - Array Extension

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
