import Foundation
import Combine

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

    var totalUnreadCount: Int {
        conversations.reduce(0) { $0 + $1.unreadCount }
    }

    private var inboxClient: WebSocketClient?       // /chat (NIP-17 gift wraps)
    private var nip04Client: WebSocketClient?        // /inbox (NIP-04 legacy DMs)
    private var externalClients: [WebSocketClient] = [] // temporary external relay clients
    private var cancellables = Set<AnyCancellable>()
    /// Subscriptions tied to the current chat/NIP-04 clients.
    /// Cancelled on reconnect to prevent stale clients from firing events.
    private var connectionCancellables = Set<AnyCancellable>()
    private var seenGiftWrapIds = Set<String>()
    private let maxSeenGiftWrapIds = 10_000

    /// Gift wraps that opened to something that is not a chat message (or
    /// could never be opened). Saved per account, so a launch does not send
    /// them to a remote signer again — with NIP-46 each one costs the user's
    /// signer two NIP-44 decrypts, every launch, forever.
    private var unreadableGiftWrapIds = Set<String>()
    private let maxUnreadableGiftWrapIds = 5_000

    /// Gift wraps waiting to be opened. Drained newest first by at most
    /// `maxGiftWrapWorkers` at a time: the backlog used to start one Task per
    /// wrap at once, which flooded a remote signer with decrypt requests.
    private var pendingGiftWraps: [NostrEvent] = []
    private var giftWrapWorkers = 0
    private let maxGiftWrapWorkers = 1

    /// Rebuild the dedup set from retained conversation messages once it
    /// outgrows the cap — it otherwise accumulates an entry for every gift
    /// wrap ever observed across a long-running session.
    private func trimSeenGiftWrapIdsIfNeeded() {
        guard seenGiftWrapIds.count > maxSeenGiftWrapIds else { return }
        seenGiftWrapIds = Set(conversations.flatMap { $0.messages.map { $0.id } })
            .union(unreadableGiftWrapIds)
    }
    private var dmUpdateSubject = PassthroughSubject<Void, Never>()
    private let processingQueue = DispatchQueue(label: "com.haven.dm-processing", qos: .userInitiated)
    private var pendingAuthChallenge: String?
    private var isAuthenticated = false
    private var loadedAccountPubkey: String = ""
    private var switchGeneration: UInt64 = 0 // incremented on each account switch to invalidate stale callbacks

    // Watch-only (local signing with no usable key) can neither decrypt NIP-04
    // DMs nor sign NIP-42 AUTH. Without gating, a catch-up batch logs one
    // identical "no key" error per DM and every AUTH challenge logs a failure.
    // These latch the notice to once per incapable streak; reset on account switch.
    private var warnedNIP04Unavailable = false
    private var warnedAuthUnavailable = false

    /// Tracks event IDs already injected into the local relay to prevent duplicate writes.
    private var injectedDmIds = Set<String>()
    private let maxInjectedDmIds = 5_000

    /// Persisted timestamp for efficient DM catch-up from external relays.
    private let lastExternalFetchKey = "com.haven.dm.lastExternalFetchTimestamp"
    var lastExternalFetchTimestamp: Int64 {
        get { Int64(UserDefaults.standard.integer(forKey: lastExternalFetchKey)) }
        set { UserDefaults.standard.set(Int(newValue), forKey: lastExternalFetchKey) }
    }

    private init() {
        loadedAccountPubkey = NostrService.shared.activeHexPubkey
        setupThrottling()
        loadConversations()

        // React to account switches only (not every config save)
        ConfigService.shared.$config
            .map { $0.activeAccountNpub }
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleAccountSwitch()
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
                    self.connectionCancellables.removeAll()
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

        // Cancel old client subscriptions before tearing down, so stale
        // clients don't fire disconnect events that produce log spam.
        connectionCancellables.removeAll()
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
            .store(in: &connectionCancellables)

        client.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self = self, self.inboxClient === client else { return }
                switch state {
                case .connected:
                    // /chat requires NIP-42 AUTH — wait for the AUTH challenge
                    // before sending subscription
                    print("✅ DM chat relay connected, awaiting AUTH challenge...")
                case .disconnected, .error:
                    print("❌ DM chat relay disconnected")
                    self.isAuthenticated = false
                default:
                    break
                }
            }
            .store(in: &connectionCancellables)

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
            .store(in: &connectionCancellables)

        client.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self = self, self.nip04Client === client else { return }
                if state == .connected {
                    print("✅ NIP-04 inbox connected")
                    self.sendNIP04Subscription(to: client)
                }
            }
            .store(in: &connectionCancellables)

        print("🔗 Connecting to NIP-04 inbox: \(inboxURL)")
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
        #if os(macOS)
        return URL(string: "ws://127.0.0.1:\(port)/inbox")
        #else
        return URL(string: "wss://127.0.0.1:\(port)/inbox")
        #endif
    }

    private func getActivePrivateKey() throws -> String {
        let config = ConfigService.shared.config
        let activeNpub = config.activeAccountNpub.trimmingCharacters(in: .whitespacesAndNewlines)
        let signingAsOwner = activeNpub.isEmpty || activeNpub == config.ownerNpub

        if signingAsOwner {
            if !config.ownerNcryptsec.isEmpty {
                guard let password = NIP49Service.getPasswordFromKeychain() else {
                    throw NSError(domain: "DMService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Password required for encrypted key"])
                }
                return try config.getDecryptedHexKey(password: password)
            } else {
                guard let key = config.ownerHexKey, !key.isEmpty else {
                    throw NSError(domain: "DMService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Sender private key not available"])
                }
                return key
            }
        } else {
            if let hexKey = try ConfigService.shared.getCredentialHexKey(forNpub: activeNpub) {
                return hexKey
            } else {
                throw NSError(domain: "DMService", code: -1, userInfo: [NSLocalizedDescriptionKey: "No private key credential stored for active account \(activeNpub.prefix(8))"])
            }
        }
    }

    /// Whether inbound NIP-04 DMs can be decrypted for the active account.
    /// Mirrors getActivePrivateKey()'s branching but only checks that key
    /// material is *present* — it never decrypts (no scrypt), so it is cheap to
    /// call per event. NIP-46 decrypts via the bunker; local mode needs a key.
    private func canDecryptNIP04() -> Bool {
        let config = ConfigService.shared.config
        if config.activeSigningMode() == "nip46" { return true }
        let activeNpub = config.activeAccountNpub.trimmingCharacters(in: .whitespacesAndNewlines)
        let signingAsOwner = activeNpub.isEmpty || activeNpub == config.ownerNpub
        if signingAsOwner {
            if !config.ownerNcryptsec.isEmpty {
                return NIP49Service.getPasswordFromKeychain() != nil
            }
            return !(config.ownerHexKey ?? "").isEmpty
        }
        return ConfigService.shared.hasCredential(forNpub: activeNpub)
    }

    /// Whether the owner account can sign (NIP-42 AUTH always signs as owner).
    /// Presence-only, like canDecryptNIP04(); NIP-46 defers to the bunker.
    private func canSignAsOwner() -> Bool {
        let config = ConfigService.shared.config
        if config.activeSigningMode() == "nip46" { return true }
        if !config.ownerNcryptsec.isEmpty {
            return NIP49Service.getPasswordFromKeychain() != nil
        }
        return !(config.ownerHexKey ?? "").isEmpty
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
        let ownHexPubkey = loadedAccountPubkey
        guard !ownHexPubkey.isEmpty else {
            throw NSError(domain: "DMService", code: -1, userInfo: [NSLocalizedDescriptionKey: "No active account loaded"])
        }

        // ── Step 1: Optimistic UI update (instant) ──
        let optimisticId = UUID().uuidString
        let message = DMMessage(
            id: optimisticId,
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

        // ── Step 2: Background crypto + network I/O ──
        let isNIP46 = ConfigService.shared.config.activeSigningMode() == "nip46"
        let senderPrivkey: String? = isNIP46 ? nil : try getActivePrivateKey()
        let rumorPTags = [["p", recipientHexPubkey]]
        let generation = self.switchGeneration

        Task { [weak self] in
            guard let self = self else { return }

            do {
                // Create both gift wraps concurrently
                async let recipientWrap = NIP17Service.createGiftWrapAsync(
                    content: content,
                    rumorPTags: rumorPTags,
                    giftWrapRecipient: recipientHexPubkey,
                    senderHexPrivkey: senderPrivkey,
                    senderHexPubkey: ownHexPubkey
                )
                async let selfWrap = NIP17Service.createGiftWrapAsync(
                    content: content,
                    rumorPTags: rumorPTags,
                    giftWrapRecipient: ownHexPubkey,
                    senderHexPrivkey: senderPrivkey,
                    senderHexPubkey: ownHexPubkey
                )

                let (giftWrap, selfGiftWrap) = try await (recipientWrap, selfWrap)

                guard self.switchGeneration == generation else { return }

                // Publish both to local relay (non-blocking, reuses persistent connection)
                self.publishToInbox(giftWrap)
                self.publishToInbox(selfGiftWrap)

                // Fetch relay lists concurrently, then fire-and-forget to external relays
                async let recipientRelays = self.fetchRecipientDMRelays(recipientHexPubkey)
                async let ownRelays = self.fetchRecipientDMRelays(ownHexPubkey)

                let rRelays = await recipientRelays
                let oRelays = await ownRelays

                for relayURL in rRelays {
                    self.fireAndForgetPublish(giftWrap, url: relayURL)
                }
                for relayURL in oRelays {
                    self.fireAndForgetPublish(selfGiftWrap, url: relayURL)
                }
            } catch {
                print("DMService: Background DM publish failed: \(error)")
            }
        }
    }

    /// Send a NIP-04 legacy DM (for compatibility with older clients)
    private func sendNIP04DM(content: String, to recipientHexPubkey: String) async throws {
        let ownHexPubkey = loadedAccountPubkey
        guard !ownHexPubkey.isEmpty else {
            throw NSError(domain: "DMService", code: -1, userInfo: [NSLocalizedDescriptionKey: "No active account loaded"])
        }
        let isNIP46 = ConfigService.shared.config.activeSigningMode() == "nip46"

        // Encrypt content using NIP-04
        let encryptedContent: String
        if isNIP46 {
            encryptedContent = try await NIP04Service.encryptAsync(plaintext: content, remotePubkey: recipientHexPubkey)
        } else {
            let senderPrivkey = try getActivePrivateKey()
            encryptedContent = try NIP04Service.encrypt(plaintext: content, remotePubkey: recipientHexPubkey, localPrivkey: senderPrivkey)
        }

        // Create kind 4 event
        let tags: [[String]] = [["p", recipientHexPubkey]]
        guard let event = await NostrService.shared.signEventAsync(kind: 4, content: encryptedContent, tags: tags) else {
            throw NSError(domain: "DMService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to sign NIP-04 event"])
        }

        // ── Optimistic UI update (uses real event ID since crypto is already done) ──
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

        // ── Background network I/O ──
        let generation = self.switchGeneration

        Task { [weak self] in
            guard let self = self else { return }
            guard self.switchGeneration == generation else { return }

            // Publish to local inbox relay
            if let inboxURL = self.inboxRelayURL()?.absoluteString {
                self.fireAndForgetPublish(event, url: inboxURL)
            }

            // Fetch relay lists concurrently, then fire-and-forget to external relays
            async let recipientRelays = self.fetchRecipientDMRelays(recipientHexPubkey)
            async let ownRelays = self.fetchRecipientDMRelays(ownHexPubkey)

            let rRelays = await recipientRelays
            let oRelays = await ownRelays

            for relayURL in rRelays {
                self.fireAndForgetPublish(event, url: relayURL)
            }
            for relayURL in oRelays where !rRelays.contains(relayURL) {
                self.fireAndForgetPublish(event, url: relayURL)
            }
        }
    }

    func markRead(conversationWith pubkey: String) {
        guard let idx = conversations.firstIndex(where: { $0.id == pubkey }) else { return }
        conversations[idx].unreadCount = 0
        saveConversations()
    }

    func markAllAsRead() {
        for idx in conversations.indices {
            conversations[idx].unreadCount = 0
        }
        saveConversations()
    }

    /// Called on app foreground. Fetches external DMs if enough time has elapsed.
    func syncOnForeground() {
        let now = Int64(Date().timeIntervalSince1970)
        let lastFetch = lastExternalFetchTimestamp
        // Don't refetch if we just did it recently (within 5 minutes)
        guard now - lastFetch > 300 else { return }
        fetchFromExternalRelays()
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
        let ownPubkey = loadedAccountPubkey
        guard !ownPubkey.isEmpty else { return }

        let generation = self.switchGeneration

        var relays = ConfigService.shared.config.activeBlastrRelays
        if relays.isEmpty {
            relays = ["wss://relay.primal.net", "wss://nos.lol"]
        }

        // Include own DM relays so we can discover sent messages from other devices
        if let ownDMRelays = NostrService.shared.dmRelayLists[ownPubkey] {
            for relay in ownDMRelays where !relays.contains(relay) {
                relays.append(relay)
            }
        }

        // Include counterpart DM relays — messages to us are published there
        let maxRelays = 15
        for conversation in conversations {
            guard relays.count < maxRelays else { break }
            if let counterpartRelays = NostrService.shared.dmRelayLists[conversation.id] {
                for relay in counterpartRelays where !relays.contains(relay) {
                    relays.append(relay)
                    if relays.count >= maxRelays { break }
                }
            }
        }

        print("🌐 Fetching DMs from \(relays.count) external relays...")

        for urlStr in relays {
            guard let url = URL(string: urlStr) else { continue }

            let client = WebSocketClient()
            client.isTemporary = true
            externalClients.append(client)

            client.messageSubject
                .receive(on: processingQueue)
                .sink { [weak self] message in
                    guard let self = self else { return }
                    // Discard if account switched since this fetch started
                    DispatchQueue.main.async {
                        guard self.switchGeneration == generation else { return }
                        self.processExternalMessage(message, forAccount: ownPubkey)
                    }
                }
                .store(in: &cancellables)

            client.$connectionState
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak client] state in
                    guard let self = self, let client = client else { return }
                    guard self.switchGeneration == generation else {
                        client.disconnect()
                        return
                    }
                    if state == .connected {
                        // Use 1-hour overlap for clock drift safety
                        let since = max(0, self.lastExternalFetchTimestamp - 3600)

                        // NIP-17 gift wraps. created_at is randomized up to 2
                        // days into the past, so the 1-hour overlap above would
                        // miss most new ones — floor the window at 2 days.
                        var nip17Filter: [String: Any] = [
                            "kinds": [1059],
                            "#p": [ownPubkey],
                            "limit": 500
                        ]
                        if since > 0 {
                            let wrapFloor = Int64(Date().timeIntervalSince1970) - (2 * 24 * 3600 + 60)
                            nip17Filter["since"] = min(since, wrapFloor)
                        }
                        let req1 = ["REQ", "ext-nip17-\(UUID().uuidString.prefix(6))", nip17Filter] as [Any]
                        if let data = try? JSONSerialization.data(withJSONObject: req1),
                           let str = String(data: data, encoding: .utf8) {
                            client.send(text: str)
                        }

                        // NIP-04 legacy DMs (received)
                        var nip04FilterReceived: [String: Any] = [
                            "kinds": [4],
                            "#p": [ownPubkey],
                            "limit": 500
                        ]
                        if since > 0 { nip04FilterReceived["since"] = since }
                        let req2 = ["REQ", "ext-nip04-in-\(UUID().uuidString.prefix(6))", nip04FilterReceived] as [Any]
                        if let data = try? JSONSerialization.data(withJSONObject: req2),
                           let str = String(data: data, encoding: .utf8) {
                            client.send(text: str)
                        }

                        // NIP-04 legacy DMs (sent)
                        var nip04FilterSent: [String: Any] = [
                            "kinds": [4],
                            "authors": [ownPubkey],
                            "limit": 500
                        ]
                        if since > 0 { nip04FilterSent["since"] = since }
                        let req3 = ["REQ", "ext-nip04-out-\(UUID().uuidString.prefix(6))", nip04FilterSent] as [Any]
                        if let data = try? JSONSerialization.data(withJSONObject: req3),
                           let str = String(data: data, encoding: .utf8) {
                            client.send(text: str)
                        }

                        // Disconnect after timeout and update fetch timestamp
                        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                            client.disconnect()
                            self?.externalClients.removeAll { $0 === client }
                            // Update timestamp and tear down injection clients when the last external client disconnects
                            if self?.externalClients.isEmpty == true {
                                self?.lastExternalFetchTimestamp = Int64(Date().timeIntervalSince1970)
                                self?.disconnectInjectionClients()
                            }
                        }
                    }
                }
                .store(in: &cancellables)

            client.connect(url: url)
        }
    }

    /// Handles messages from external relay fetch (both NIP-17 and NIP-04)
    private func processExternalMessage(_ message: String, forAccount accountPubkey: String) {
        // Verify this message is still for the currently loaded account
        guard accountPubkey == loadedAccountPubkey else { return }

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
                // Unsigned or forged: neither show it nor store it locally.
                guard Self.isAuthentic(event) else { return }

                // Process the DM for display
                if event.kind == 1059 {
                    self.handleIncomingGiftWrap(event)
                } else if event.kind == 4 {
                    self.handleIncomingNIP04(event)
                }

                // Also inject the raw event into the local relay so it persists
                // across app restarts and syncs to other devices via the Go relay.
                self.injectExternalDmIntoLocalRelay(eventData, eventId: event.id, kind: event.kind)
            }
        } catch {
            print("❌ Failed to process external message: \(error)")
        }
    }

    /// Shared injection clients for writing fetched DMs into the local relay.
    /// Lazily connected and reused across a batch fetch to avoid per-event connections.
    private var chatInjectionClient: WebSocketClient?
    private var inboxInjectionClient: WebSocketClient?
    /// Pending events queued while the injection client is still connecting.
    private var pendingChatInjections: [[String: Any]] = []
    private var pendingInboxInjections: [[String: Any]] = []

    /// Injects an externally-fetched DM event into the local relay so it persists
    /// in the relay DB and is available on other devices via the Go relay's sync.
    private func injectExternalDmIntoLocalRelay(_ eventData: [String: Any], eventId: String, kind: Int) {
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

    private func sendEventToClient(_ client: WebSocketClient, _ eventData: [String: Any]) {
        let msg = ["EVENT", eventData] as [Any]
        if let data = try? JSONSerialization.data(withJSONObject: msg),
           let str = String(data: data, encoding: .utf8) {
            client.send(text: str)
        }
    }

    private func injectViaChatClient(_ eventData: [String: Any]) {
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
    private func disconnectInjectionClients() {
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

    // MARK: - Private Methods

    private func sendInboxSubscription(to client: WebSocketClient) {
        let ownPubkey = loadedAccountPubkey
        guard !ownPubkey.isEmpty else { return }
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
        guard let client = inboxClient else { return }

        // Watch-only: no owner key to sign NIP-42 AUTH. Skip the attempt (the
        // chat relay simply stays unauthenticated — nothing to read there anyway)
        // and warn once instead of logging a signing failure per AUTH challenge.
        guard canSignAsOwner() else {
            if !warnedAuthUnavailable {
                warnedAuthUnavailable = true
                print("ℹ️ Watch-only: cannot sign NIP-42 AUTH (no owner key) — chat relay left unauthenticated")
            }
            return
        }

        // The relay tag must match the relay's ServiceURL (its public-facing URL),
        // NOT the localhost connection URL. Khatru validates the relay tag against
        // "wss://" + config.RelayURL + "/chat", so we must use the same value here.
        let relayURL = ConfigService.shared.config.nostrURL + "/chat"

        // Sign a NIP-42 AUTH event (kind 22242)
        let tags: [[String]] = [
            ["relay", relayURL],
            ["challenge", challenge]
        ]

        Task {
            // Always sign AUTH with owner's key since the local relay is owned by the owner account
            guard let authEvent = await NostrService.shared.signEventAsync(kind: 22242, content: "", tags: tags, forceOwner: true) else {
                print("Failed to sign NIP-42 AUTH event")
                return
            }

            // Send ["AUTH", <signed_event>]
            let eventDict = eventToDict(authEvent)
            let msg = ["AUTH", eventDict] as [Any]
            if let data = try? JSONSerialization.data(withJSONObject: msg),
               let str = String(data: data, encoding: .utf8) {
                print("Sending AUTH response...")
                client.send(text: str)
            }
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
        // Checked before marking the id seen, so a forged copy carrying a real
        // event's id cannot shadow the real one.
        guard Self.isAuthentic(event) else { return }

        // Watch-only: no key to decrypt NIP-04. Skip WITHOUT marking the event
        // seen (so a later unlock/reconnect can still process it) and warn once,
        // rather than logging a "no key" failure per DM across a catch-up batch.
        guard canDecryptNIP04() else {
            if !warnedNIP04Unavailable {
                warnedNIP04Unavailable = true
                print("ℹ️ Watch-only: NIP-04 DM decryption unavailable (no signing key) — skipping inbound DMs")
            }
            return
        }

        seenGiftWrapIds.insert(event.id)
        trimSeenGiftWrapIdsIfNeeded()

        let generation = self.switchGeneration

        Task {
        do {
            // Verify account hasn't switched since we started processing
            guard self.switchGeneration == generation else { return }

            let isNIP46 = ConfigService.shared.config.activeSigningMode() == "nip46"
            let ownPrivkey: String = isNIP46 ? "" : try getActivePrivateKey()

            let ownPubkey = self.loadedAccountPubkey
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
            let plaintext: String
            if ConfigService.shared.config.activeSigningMode() == "nip46" {
                plaintext = try await NIP04Service.decryptAsync(ciphertext: event.content, remotePubkey: counterpartyPubkey)
            } else {
                plaintext = try NIP04Service.decrypt(ciphertext: event.content, remotePubkey: counterpartyPubkey, localPrivkey: ownPrivkey)
            }

            // Verify account hasn't switched during async decryption
            guard self.switchGeneration == generation else { return }

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
            print("Failed to decrypt NIP-04 DM: \(error)")
        }
        } // end Task
    }

    /// A relay can serve any event under any author. NIP-04 has no MAC, so a
    /// re-IV'd copy of a real DM decrypts to altered text; only the signature
    /// ties it to its author.
    private static func isAuthentic(_ event: NostrEvent) -> Bool {
        guard let data = try? JSONEncoder().encode(event),
              let json = String(data: data, encoding: .utf8) else { return false }
        return NostrEventVerifier.isValid(json: json)
    }

    // MARK: - NIP-17 Processing

    private func handleIncomingGiftWrap(_ event: NostrEvent) {
        guard event.kind == 1059 else { return }
        guard !seenGiftWrapIds.contains(event.id) else { return }
        guard Self.isAuthentic(event) else { return }

        seenGiftWrapIds.insert(event.id)
        trimSeenGiftWrapIdsIfNeeded()

        pendingGiftWraps.append(event)
        startGiftWrapWorkersIfNeeded()
    }

    private func startGiftWrapWorkersIfNeeded() {
        while giftWrapWorkers < maxGiftWrapWorkers && !pendingGiftWraps.isEmpty {
            giftWrapWorkers += 1
            let generation = switchGeneration
            Task { await drainGiftWraps(generation: generation) }
        }
    }

    private func drainGiftWraps(generation: UInt64) async {
        while generation == switchGeneration, let next = popNewestGiftWrap() {
            await processGiftWrap(next, generation: generation)
        }
        giftWrapWorkers -= 1
        // Work queued for a new account while this worker was finishing.
        startGiftWrapWorkersIfNeeded()
    }

    /// Newest first, so the latest messages appear before the backlog.
    private func popNewestGiftWrap() -> NostrEvent? {
        guard let index = pendingGiftWraps.indices.max(by: {
            pendingGiftWraps[$0].created_at < pendingGiftWraps[$1].created_at
        }) else { return nil }
        return pendingGiftWraps.remove(at: index)
    }

    private func processGiftWrap(_ event: NostrEvent, generation: UInt64) async {
        do {
            // Verify account hasn't switched since we started processing
            guard self.switchGeneration == generation else { return }

            let isNIP46 = ConfigService.shared.config.activeSigningMode() == "nip46"
            let recipientPrivkey: String? = isNIP46 ? nil : try getActivePrivateKey()

            let (senderPubkey, content, timestamp, rumorTags) = try await NIP17Service.unwrapGiftWrapAsync(event, recipientPrivkey: recipientPrivkey)

            // Re-check after async decryption
            guard self.switchGeneration == generation else { return }

            let ownPubkey = self.loadedAccountPubkey
            let isFromMe = senderPubkey == ownPubkey

            // Determine counterparty from the rumor's p-tags (the actual conversation participants)
            let rumorPTagPubkeys = rumorTags
                .filter { $0.count >= 2 && $0[0] == "p" }
                .map { $0[1] }

            let counterpartyPubkey: String
            if isFromMe {
                // Self-copy: counterparty is the first p-tagged pubkey that isn't us
                counterpartyPubkey = rumorPTagPubkeys.first(where: { $0 != ownPubkey }) ?? rumorPTagPubkeys.first ?? senderPubkey
            } else {
                counterpartyPubkey = senderPubkey
            }

            let message = DMMessage(
                id: event.id,
                senderPubkey: senderPubkey,
                content: content,
                timestamp: timestamp,
                isFromMe: isFromMe
            )

            #if DEBUG
            print("Received DM from \(senderPubkey.prefix(8)): \(content.prefix(50))")
            #endif

            if let idx = conversations.firstIndex(where: { $0.id == counterpartyPubkey }) {
                guard !conversations[idx].messages.contains(where: { $0.id == event.id }) else { return }

                // If this is our own message returning from the relay, replace the
                // optimistic placeholder (which has a UUID id) with the real event.
                if isFromMe {
                    let recentThreshold = Date().addingTimeInterval(-30)
                    if let msgIdx = conversations[idx].messages.lastIndex(where: {
                        $0.isFromMe && $0.content == content && $0.timestamp > recentThreshold
                    }) {
                        conversations[idx].messages[msgIdx] = message
                        seenGiftWrapIds.insert(event.id)
                        saveConversations()
                        return
                    }
                }

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
        } catch let error as NIP17Service.NIP17Error {
            // The wrap opened to something that is not a chat message (or
            // cannot be opened with this key): it will not change, so do not
            // ask the signer about it again on the next launch.
            print("Failed to unwrap gift wrap: \(error)")
            guard self.switchGeneration == generation else { return }
            rememberUnreadableGiftWrap(event.id)
        } catch {
            // Signer offline, timed out or refused: try again next launch.
            print("Failed to unwrap gift wrap: \(error)")
        }
    }

    private func rememberUnreadableGiftWrap(_ id: String) {
        guard unreadableGiftWrapIds.insert(id).inserted else { return }
        if unreadableGiftWrapIds.count > maxUnreadableGiftWrapIds {
            unreadableGiftWrapIds = Set(unreadableGiftWrapIds.shuffled().prefix(maxUnreadableGiftWrapIds))
        }
        saveUnreadableGiftWrapIds()
    }

    private func handleAccountSwitch() {
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
        injectedDmIds.removeAll()
        isAuthenticated = false
        pendingAuthChallenge = nil

        // Tear down injection clients from previous account
        disconnectInjectionClients()

        // Load new account's conversations
        loadConversations()

        reconnectInbox()
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
        #if os(macOS)
        return URL(string: "ws://127.0.0.1:\(port)/chat")
        #else
        return URL(string: "wss://127.0.0.1:\(port)/chat")
        #endif
    }

    private func fetchRecipientDMRelays(_ pubkey: String) async -> [String] {
        // Someone else's advertised 127.0.0.1 resolves to OUR machine, so
        // publishing there drops their DM into our own relay — the write
        // succeeds and the message is simply lost. Older builds advertised
        // exactly that, so these entries are out there and must be dropped.
        // Filtering can empty a list; falling through to the next source is
        // what keeps that from silently sending nowhere.
        func reachable(_ relays: [String]) -> [String] {
            relays.filter { !NostrService.isLoopbackRelay($0) }
        }

        // NIP-17: Check kind 10050 (DM relay preferences) first
        if let dmRelays = NostrService.shared.dmRelayLists[pubkey] {
            let usable = reachable(dmRelays)
            if !usable.isEmpty {
                print("📋 Using NIP-17 DM relays for \(pubkey.prefix(8)): \(usable)")
                return usable
            }
            if !dmRelays.isEmpty {
                print("⚠️ \(pubkey.prefix(8)) advertises only loopback DM relays — falling back")
            }
        }

        // Fallback to kind 10002 (general read relays)
        if let readRelays = NostrService.shared.relayLists[pubkey] {
            let usable = reachable(readRelays)
            if !usable.isEmpty {
                print("📋 Using kind 10002 relay list for \(pubkey.prefix(8)): \(usable)")
                return usable
            }
        }

        // Trigger a fetch and wait briefly for results
        NostrService.shared.fetchRelayList(for: pubkey)

        // Wait up to 4 seconds for the relay lists to populate
        for _ in 0..<8 {
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s

            // Check kind 10050 first
            if let dmRelays = NostrService.shared.dmRelayLists[pubkey] {
                let usable = reachable(dmRelays)
                if !usable.isEmpty {
                    print("📋 Fetched NIP-17 DM relays for \(pubkey.prefix(8)): \(usable)")
                    return usable
                }
            }

            // Then check kind 10002
            if let readRelays = NostrService.shared.relayLists[pubkey] {
                let usable = reachable(readRelays)
                if !usable.isEmpty {
                    print("📋 Fetched kind 10002 relay list for \(pubkey.prefix(8)): \(usable)")
                    return usable
                }
            }
        }

        // Fallback: use common relays where most users have inbox
        let fallbackRelays = ConfigService.shared.config.activeBlastrRelays.isEmpty
            ? ["wss://relay.primal.net", "wss://nos.lol"]
            : ConfigService.shared.config.activeBlastrRelays
        print("⚠️ No relay list for \(pubkey.prefix(8)), using fallback relays")
        return fallbackRelays
    }

    /// Publishes an event to the local /chat relay.
    /// Reuses the persistent inboxClient when connected (zero latency).
    /// Falls back to the injection client pattern (queues + sends on connect).
    private func publishToInbox(_ event: NostrEvent) {
        let eventDict = eventToDict(event)

        // Fast path: reuse the already-connected persistent inbox client
        if let client = inboxClient, client.connectionState == .connected {
            sendEventToClient(client, eventDict)
            return
        }

        // Fallback: queue via injection client (sends on connect)
        injectViaChatClient(eventDict)
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

    /// Fire-and-forget publish to an external relay.
    /// Connects, sends EVENT, and disconnects after a short flush window.
    /// Does NOT block the caller — errors are logged but not propagated.
    private func fireAndForgetPublish(_ event: NostrEvent, url: String) {
        guard let urlObj = URL(string: url) else { return }

        let client = WebSocketClient()
        client.isTemporary = true
        let eventDict = eventToDict(event)

        let sub = client.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { state in
                if state == .connected {
                    let msg = ["EVENT", eventDict] as [Any]
                    if let data = try? JSONSerialization.data(withJSONObject: msg),
                       let str = String(data: data, encoding: .utf8) {
                        client.send(text: str)
                    }
                    // Short flush window for TCP send buffer, then disconnect
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        client.disconnect()
                    }
                } else if case .error = state {
                    client.disconnect()
                }
            }
        self.cancellables.insert(sub)

        // Connect timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if client.connectionState != .connected {
                client.disconnect()
            }
        }

        client.connect(url: urlObj)
    }

    /// Async wrapper around fireAndForgetPublish for call sites that use `await`.
    private func publishToRelay(_ event: NostrEvent, url: String) async {
        fireAndForgetPublish(event, url: url)
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

        // Legacy migration: the old shared cache contained messages from ALL accounts.
        // Instead of moving the entire file (which mixes accounts), delete it and let
        // each account re-fetch its own messages from relays on next connect.
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            let legacy = legacyCacheFileURL()
            if FileManager.default.fileExists(atPath: legacy.path) {
                try? FileManager.default.removeItem(at: legacy)
            }
        }

        if let data = try? Data(contentsOf: unreadableFileURL()),
           let ids = try? JSONDecoder().decode([String].self, from: data) {
            unreadableGiftWrapIds = Set(ids)
            seenGiftWrapIds.formUnion(unreadableGiftWrapIds)
        }

        guard let data = try? Data(contentsOf: fileURL) else { return }
        conversations = (try? JSONDecoder().decode([DMConversation].self, from: data)) ?? []

        // Seed seenGiftWrapIds from cached messages to prevent duplicates on reconnect
        for conversation in conversations {
            for message in conversation.messages {
                seenGiftWrapIds.insert(message.id)
            }
        }
    }

    private func saveUnreadableGiftWrapIds() {
        guard let data = try? JSONEncoder().encode(Array(unreadableGiftWrapIds)) else { return }
        try? data.write(to: unreadableFileURL())
    }

    /// Beside the conversation cache, same per-account suffix.
    private func unreadableFileURL() -> URL {
        let cache = cacheFileURL()
        let name = cache.lastPathComponent.replacingOccurrences(of: "dm_cache", with: "dm_unreadable")
        return cache.deletingLastPathComponent().appendingPathComponent(name)
    }

    private func saveConversations() {
        let fileURL = cacheFileURL()
        guard let data = try? JSONEncoder().encode(conversations) else { return }
        try? data.write(to: fileURL)
    }

    private func cacheFileURL(forPubkey pubkey: String? = nil) -> URL {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Haven")
        }
        let havenDir = appSupport.appendingPathComponent("Haven", isDirectory: true)
        try? FileManager.default.createDirectory(at: havenDir, withIntermediateDirectories: true)
        let key = pubkey ?? loadedAccountPubkey
        let suffix = key.isEmpty ? "owner" : String(key.prefix(16))
        return havenDir.appendingPathComponent("dm_cache_\(suffix).json")
    }

    private func legacyCacheFileURL() -> URL {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Haven")
        }
        let havenDir = appSupport.appendingPathComponent("Haven", isDirectory: true)
        return havenDir.appendingPathComponent("dm_cache.json")
    }
}

// MARK: - Array Extension

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
