import Foundation
import Combine
import SwiftUI

@MainActor
class NostrService: ObservableObject {
    private struct UncheckedSendable<T>: @unchecked Sendable {
        let value: T
    }

    static let shared = NostrService()
    // These are no longer @Published to prevent background-thread notification crashes.
    // We notify manually on the main thread via the throttled subject.
    private(set) var events: [NostrEvent] = []
    private(set) var noteMedia: [MediaItem] = []

    // Aggregated status
    @Published var connectionStatus: String = "Disconnected"
    @Published var connectionColor: String = "gray"
    @Published var isFetching: Bool = false

    private var seenEventIds = Set<String>()
    private var clients: [String: WebSocketClient] = [:]
    private var activeSubscriptions: [String: String] = [:] // [RelayURL: SubID]
    private var cancellables = Set<AnyCancellable>()
    private let processingQueue = DispatchQueue(label: "com.haven.nostr-processing", qos: .userInitiated)

    // Relay List Metadata Cache (Kind 10002)
    @Published var relayLists: [String: [String]] = [:] // [Pubkey: [InboxRelayURLs]]
    private var relaysInFlight = Set<String>()

    // Batching updates to the UI
    private let eventUpdateSubject = PassthroughSubject<Void, Never>()

    // Buffered event batching — avoids per-event main thread dispatch
    private var eventBuffer: [(NostrEvent, [MediaItem])] = []
    private let bufferLock = NSLock()
    private var bufferFlushTimer: Timer?

    // Pagination tracking
    private var activeSubscriptionCount = 0
    private var profilesInFlight = Set<String>()
    private var profileFetchQueue = Set<String>()
    private var profileFlushCancellable: AnyCancellable?

    // Used to distinguish live incoming events from historical backfill on startup.
    // Only events newer than this date fire push notifications.
    // Reset each time the app wakes from a silent push so fresh events are "new".
    var sessionStartDate: Date = Date()

    init() {
        setupThrottling()
        loadProfiles()
        updateOwnerHex()
        prefetchWhitelistedProfiles()

        // Handle npub changes (e.g. after setup)
        ConfigService.shared.$config
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.updateOwnerHex()
                self.prefetchWhitelistedProfiles()
            }
            .store(in: &cancellables)
    }

    @Published var profiles: [String: FeedProfile] = [:]
    private(set) var ownerHexPubkey: String = ""

    /// The active browsing identity hex pubkey. Falls back to owner if no override is set.
    var activeHexPubkey: String {
        ConfigService.shared.activeAccountHexPubkey
    }

    private var lastConnectLog: Date = .distantPast
    private func shouldLogConnect() -> Bool {
        let now = Date()
        if now.timeIntervalSince(lastConnectLog) > 5.0 {
            lastConnectLog = now
            return true
        }
        return false
    }

    private func updateOwnerHex() {
        let npub = ConfigService.shared.config.ownerNpub
        if let hex = Bech32.decode(npub)?.hexString {
            self.ownerHexPubkey = hex
            #if DEBUG
            print("NostrService: Owner Hex Pubkey: \(hex)")
            #endif
        } else {
            self.ownerHexPubkey = ""
        }
    }

    /// Pre-fetches profiles for the owner + all whitelisted npubs so avatars
    /// are ready when the account switcher is opened.
    private func prefetchWhitelistedProfiles() {
        let allNpubs = ConfigService.shared.allAccountNpubs
        let hexPubkeys = allNpubs.compactMap { npub -> String? in
            let trimmed = npub.trimmingCharacters(in: .whitespacesAndNewlines)
            return Bech32.decode(trimmed)?.hexString
        }
        fetchMissingProfiles(for: hexPubkeys)
    }

    private func setupMetadataFlusher() {
        profileFlushCancellable = Timer.publish(every: 0.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.flushMetadataRequests()
            }
    }

    private func flushMetadataRequests() {
        guard !profileFetchQueue.isEmpty else { return }
        let pubkeys = Array(profileFetchQueue)
        profileFetchQueue.removeAll()

        // Use blastr relays or defaults if empty
        var relays = ConfigService.shared.config.blastrRelays
        if relays.isEmpty {
            relays = ["wss://relay.damus.io", "wss://relay.primal.net", "wss://nos.lol"]
        }

        #if DEBUG
        print("NostrService: Batch fetching metadata for \(pubkeys.count) pubkeys from \(relays.count) Blastr relays")
        #endif

        let uniqueRelays = Array(Set(relays)).compactMap { URL(string: $0) }

        for url in uniqueRelays {
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
                .sink { [weak self] state in
                    guard let self = self else { return }
                    if state == .connected {
                        self.sendProfileRequest(to: client, pubkeys: pubkeys)
                        // Disconnect after results come in (or reasonable timeout)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                            client.disconnect()
                        }
                    }
                }
                .store(in: &cancellables)

            client.connect(url: url)
        }
    }

    private func loadProfiles() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let havenDir = appSupport.appendingPathComponent("Haven", isDirectory: true)
        let profileURL = havenDir.appendingPathComponent("profiles.json")

        if let data = try? Data(contentsOf: profileURL),
           let loaded = try? JSONDecoder().decode([String: FeedProfile].self, from: data) {
            self.profiles = loaded
            #if DEBUG
            print("NostrService: Loaded \(profiles.count) profiles from cache")
            #endif
        }

        // Load Relay Lists
        let relayListsURL = havenDir.appendingPathComponent("relay_lists.json")
        if let data = try? Data(contentsOf: relayListsURL),
           let loaded = try? JSONDecoder().decode([String: [String]].self, from: data) {
            self.relayLists = loaded
            #if DEBUG
            print("NostrService: Loaded \(relayLists.count) relay lists from cache")
            #endif
        }

    }


    // Unified cache structure
    private var lastProfileSave: Date = .distantPast
    private let profileSaveThrottle: TimeInterval = 5.0

    private func saveProfilesThrottled() {
        let now = Date()
        if now.timeIntervalSince(lastProfileSave) > profileSaveThrottle {
            lastProfileSave = now
            saveProfiles()
            saveRelayLists()
        }
    }

    private func saveRelayLists() {
        let listsCopy = relayLists
        DispatchQueue.global(qos: .utility).async {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let havenDir = appSupport.appendingPathComponent("Haven", isDirectory: true)
            let relayListsURL = havenDir.appendingPathComponent("relay_lists.json")

            if let data = try? JSONEncoder().encode(listsCopy) {
                try? data.write(to: relayListsURL)
            }
        }
    }

    private func saveProfiles() {

        let profilesCopy = profiles
        DispatchQueue.global(qos: .utility).async {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let havenDir = appSupport.appendingPathComponent("Haven", isDirectory: true)

            // Ensure directory exists
            try? FileManager.default.createDirectory(at: havenDir, withIntermediateDirectories: true)
            let profileURL = havenDir.appendingPathComponent("profiles.json")

            if let data = try? JSONEncoder().encode(profilesCopy) {
                try? data.write(to: profileURL)
                #if DEBUG
                // print("NostrService: Saved \(profilesCopy.count) profiles to cache")
                #endif
            }
        }
    }

    func fetchMissingProfiles(for pubkeys: [String], force: Bool = false) {
        let missing = pubkeys.filter { (force || profiles[$0] == nil) && !profilesInFlight.contains($0) }
        guard !missing.isEmpty else { return }

        for pubkey in missing {
            profilesInFlight.insert(pubkey)
            profileFetchQueue.insert(pubkey)
            // Also fetch their relay list for smart broadcasting
            fetchRelayList(for: pubkey)
        }

        if profileFlushCancellable == nil {
            setupMetadataFlusher()
        }
    }


    private func sendProfileRequest(to client: WebSocketClient, pubkeys: [String]) {
        let subscriptionId = "meta-\(UUID().uuidString.prefix(8))"
        let filter: [String: Any] = [
            "kinds": [0, 10002, 10000],
            "authors": pubkeys
        ]

        let req = ["REQ", subscriptionId, filter] as [Any]

        if let reqData = try? JSONSerialization.data(withJSONObject: req),
           let reqString = String(data: reqData, encoding: .utf8) {
            client.send(text: reqString)
        }
    }

    func fetchRelayList(for pubkey: String) {
        guard relayLists[pubkey] == nil && !relaysInFlight.contains(pubkey) else { return }
        relaysInFlight.insert(pubkey)

        // Use blastr relays or defaults if empty
        var relays = ConfigService.shared.config.blastrRelays
        if relays.isEmpty {
            relays = ["wss://relay.damus.io", "wss://relay.primal.net", "wss://nos.lol"]
        }

        #if DEBUG
        print("NostrService: Fetching relay list (10002) for \(pubkey.prefix(8))...")
        #endif

        let uniqueRelays = Array(Set(relays)).compactMap { URL(string: $0) }

        // Safety net: clear the in-flight guard 10s after the attempt starts
        // regardless of outcome, so a failed fetch can be retried later.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.relaysInFlight.remove(pubkey)
        }

        for url in uniqueRelays {
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
                    if state == .connected {
                        let subscriptionId = "relays-\(UUID().uuidString.prefix(8))"
                        let filter: [String: Any] = [
                            "kinds": [10002],
                            "authors": [pubkey],
                            "limit": 1
                        ]

                        let req = ["REQ", subscriptionId, filter] as [Any]
                        if let reqData = try? JSONSerialization.data(withJSONObject: req),
                           let reqString = String(data: reqData, encoding: .utf8) {
                            client.send(text: reqString)
                        }

                        // Disconnect after reasonable timeout
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                            client.disconnect()
                        }
                    }
                }
                .store(in: &cancellables)

            client.connect(url: url)
        }
    }

    func resetConnections() {
        for client in clients.values {
            client.disconnect()
        }
        clients.removeAll()
        activeSubscriptions.removeAll()
        cancellables.removeAll()
        bufferFlushTimer?.invalidate()
        bufferFlushTimer = nil
        bufferLock.lock()
        eventBuffer.removeAll()
        bufferLock.unlock()
        setupThrottling()
    }

    private func setupThrottling() {
        // Debounce UI updates to prevent main thread saturation and fix NSStatusItem threading crash
        eventUpdateSubject
            .throttle(for: .milliseconds(250), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    // MARK: - Publishing

    /// Signs an event using the stored nsec via the Go backend
    /// - Parameters:
    ///   - kind: The event kind
    ///   - content: The event content
    ///   - tags: The event tags
    ///   - password: Optional password for NIP-49 encrypted keys. If not provided, will attempt to retrieve from Keychain.
    /// - Returns: The signed NostrEvent, or nil if signing fails
    func signEvent(kind: Int, content: String, tags: [[String]] = [], password: String? = nil) -> NostrEvent? {
        var sk: String?
        let config = ConfigService.shared.config
        
        // Determine which account is signing
        let activeNpub = config.activeAccountNpub.trimmingCharacters(in: .whitespacesAndNewlines)
        let signingAsOwner = activeNpub.isEmpty || activeNpub == config.ownerNpub
        
        if signingAsOwner {
            // ── Owner signing path (existing logic) ──────────────────────────
            if !config.ownerNcryptsec.isEmpty {
                let pwd = password ?? NIP49Service.getPasswordFromKeychain()
                if let pwd = pwd {
                    do {
                        sk = try config.getDecryptedHexKey(password: pwd)
                    } catch {
                        print("NostrService: NIP-49 decrypt failed: \(error.localizedDescription)")
                        return nil
                    }
                } else {
                    print("NostrService: NIP-49 key exists but no password in Keychain")
                    return nil
                }
            } else {
                sk = config.ownerHexKey
            }
        } else {
            // ── Whitelisted account signing path ─────────────────────────────
            do {
                if let hexKey = try ConfigService.shared.getCredentialHexKey(forNpub: activeNpub) {
                    sk = hexKey
                } else {
                    // No credential stored for this account — fall back to owner key
                    print("NostrService: No credential for active account \(activeNpub.prefix(16))..., falling back to owner")
                    if !config.ownerNcryptsec.isEmpty {
                        let pwd = password ?? NIP49Service.getPasswordFromKeychain()
                        if let pwd = pwd {
                            sk = try config.getDecryptedHexKey(password: pwd)
                        }
                    } else {
                        sk = config.ownerHexKey
                    }
                }
            } catch {
                print("NostrService: Failed to decrypt whitelisted account key: \(error.localizedDescription)")
                return nil
            }
        }

        guard let sk = sk, !sk.isEmpty else {
            print("NostrService: Cannot sign - no private key available")
            return nil
        }

        // Use the active account's pubkey for the event
        let signingPubkey = signingAsOwner ? ownerHexPubkey : activeHexPubkey

        var finalTags = tags
        if !finalTags.contains(where: { $0.first == "client" }) {
            #if os(iOS)
            let clientName: String
            if UIDevice.current.userInterfaceIdiom == .pad {
                clientName = "Nostr Vault on iPadOS"
            } else {
                clientName = "Nostr Vault on iOS"
            }
            #else
            let clientName = "Nostr Vault on MacOS"
            #endif
            finalTags.append(["client", clientName])
        }

        let eventDict: [String: Any] = [
            "pubkey": signingPubkey,
            "created_at": Int64(Date().timeIntervalSince1970),
            "kind": kind,
            "content": content,
            "tags": finalTags
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: eventDict),
              let jsonStr = String(data: jsonData, encoding: .utf8) else {
            print("NostrService: Failed to serialize event to JSON")
            return nil
        }

        // Call Go backend for signing
        guard let signedCStr = SignEventC(UnsafeMutablePointer(mutating: (jsonStr as NSString).utf8String), UnsafeMutablePointer(mutating: (sk as NSString).utf8String)) else {
            print("NostrService: SignEventC returned nil (Go signing failed)")
            return nil
        }

        let signedJsonStr = String(cString: signedCStr)
        free(signedCStr)

        guard let signedData = signedJsonStr.data(using: .utf8) else {
            print("NostrService: Failed to convert signed JSON to Data")
            return nil
        }

        do {
            return try JSONDecoder().decode(NostrEvent.self, from: signedData)
        } catch {
            print("NostrService: Failed to decode signed event: \(error) — JSON: \(signedJsonStr.prefix(200))")
            return nil
        }
    }

    /// Publishes a signed Kind 10000 (Mute List) event to configured relays for the active account
    @MainActor
    func publishMuteList(for accountNpub: String, blockedNpubs: [String]) {
        // Convert npubs to hex pubkeys
        let hexKeys = blockedNpubs.compactMap { npub -> String? in
            let clean = npub.trimmingCharacters(in: .whitespacesAndNewlines)
            return Bech32.decode(clean)?.hexString
        }
        
        let tags = hexKeys.map { ["p", $0] }
        
        // Temporarily store the active account so we sign as the target account
        let originalActive = ConfigService.shared.config.activeAccountNpub
        
        // Temporarily set activeAccountNpub to sign with the correct key
        ConfigService.shared.config.activeAccountNpub = (accountNpub == ConfigService.shared.config.ownerNpub) ? "" : accountNpub
        
        // Sign event
        if let event = signEvent(kind: 10000, content: "", tags: tags) {
            postEvent(event)
            
            // Restore active account and save sync timestamp
            ConfigService.shared.config.activeAccountNpub = originalActive
            ConfigService.shared.config.blockedNpubsLastSyncTimestamp[accountNpub] = event.created_at
            ConfigService.shared.save()
            #if DEBUG
            print("NostrService: Successfully published Kind 10000 mute list with \(tags.count) tags for \(accountNpub.prefix(8))")
            #endif
        } else {
            // Restore active account on failure
            ConfigService.shared.config.activeAccountNpub = originalActive
            print("NostrService: Failed to sign Kind 10000 mute list for \(accountNpub.prefix(8))")
        }
    }

    /// Posts an event to the local relay and broadcasts to configured relays
    func postEvent(_ event: NostrEvent) {
        // Update local state immediately for instant feedback
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if !self.seenEventIds.contains(event.id) {
                self.seenEventIds.insert(event.id)
                self.events.insert(event, at: 0)
                self.events.sort(by: { $0.created_at > $1.created_at })

                // Extract media URLs and add to noteMedia
                let urls = self.extractMediaURLs(from: event.content)
                let items = urls.map { url in
                    let mime = Self.mimeFromExtension(url)
                    let mediaType = Self.mediaTypeFromMime(mime, url: url)
                    return MediaItem(id: UUID(), url: url, type: mediaType, dateAdded: event.createdAtDate, pubkey: event.pubkey, tags: event.tags, mimeType: mime)
                }
                if !items.isEmpty {
                    self.noteMedia.append(contentsOf: items)
                }

                self.eventUpdateSubject.send()
            }
        }

        let msg = ["EVENT", [
            "id": event.id,
            "pubkey": event.pubkey,
            "created_at": event.created_at,
            "kind": event.kind,
            "tags": event.tags,
            "content": event.content,
            "sig": event.sig
        ] as [String : Any]] as [Any]

        guard let data = try? JSONSerialization.data(withJSONObject: msg),
              let str = String(data: data, encoding: .utf8) else { return }

        // 1. Post to local relay
        let localURL = URL(string: ConfigService.shared.config.nostrURL)!
        let localClient = WebSocketClient()
        localClient.isTemporary = true

        localClient.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { state in
                if state == .connected {
                    localClient.send(text: str)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        localClient.disconnect()
                    }
                }
            }
            .store(in: &cancellables)

        localClient.connect(url: localURL)

        // 2. Broadcast to Blastr relays
        let blastrRelays = ConfigService.shared.config.blastrRelays
        if !blastrRelays.isEmpty {
            for relayURLString in blastrRelays {
                guard let url = URL(string: relayURLString) else { continue }
                let broadcastClient = WebSocketClient()
                broadcastClient.isTemporary = true

                broadcastClient.$connectionState
                    .receive(on: DispatchQueue.main)
                    .sink { state in
                        if state == .connected {
                            #if DEBUG
                            print("NostrService: Broadcasting event \(event.id.prefix(8)) to \(relayURLString)")
                            #endif
                            broadcastClient.send(text: str)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                broadcastClient.disconnect()
                            }
                        }
                    }
                    .store(in: &cancellables)

                broadcastClient.connect(url: url)
            }
        }

        // 3. Smart Broadcast: Send to author's inbox relays if it's a reply or reaction
        if event.kind == 1 || event.kind == 6 || event.kind == 7 {
            // Find target author's pubkey from 'p' tags (skipping own pubkey)
            let targetPubkey = event.tags.first { $0.count >= 2 && $0[0] == "p" && $0[1] != activeHexPubkey }?[1]

            if let targetPubkey = targetPubkey, let targetRelays = relayLists[targetPubkey] {
                #if DEBUG
                print("NostrService: Smart broadcast event \(event.id.prefix(8)) to \(targetPubkey.prefix(8))'s inbox relays: \(targetRelays)")
                #endif

                for relayURLString in targetRelays {
                    // Skip if already sent to this relay via blastr
                    if blastrRelays.contains(relayURLString) { continue }

                    guard let url = URL(string: relayURLString) else { continue }
                    let smartClient = WebSocketClient()
                    smartClient.isTemporary = true

                    smartClient.$connectionState
                        .receive(on: DispatchQueue.main)
                        .sink { state in
                            if state == .connected {
                                smartClient.send(text: str)
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                    smartClient.disconnect()
                                }
                            }
                        }
                        .store(in: &cancellables)

                    smartClient.connect(url: url)
                }
            } else if let targetPubkey = targetPubkey {
                // We don't have their relays yet, fetch for next time
                fetchRelayList(for: targetPubkey)
            }
        }

        // Refresh stats after a short delay so the backend database has processed the event
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let config = ConfigService.shared.config
            let urlString = config.relayURL.isEmpty ? "localhost:\(config.relayPort)" : config.relayURL
            StatsService.shared.refreshStats(relayURLString: urlString)
        }
    }

    /// Broadcasts a raw signed event dict (including sig) to configured Blastr relays.
    /// Use this to re-broadcast an existing event without re-signing it.
    func broadcastRawEvent(_ eventDict: [String: Any]) {
        let msg = ["EVENT", eventDict] as [Any]
        guard let data = try? JSONSerialization.data(withJSONObject: msg),
              let str = String(data: data, encoding: .utf8) else { return }

        var relays = ConfigService.shared.config.blastrRelays
        if relays.isEmpty {
            relays = ["wss://relay.damus.io", "wss://relay.primal.net", "wss://nos.lol"]
        }

        for urlStr in relays {
            guard let url = URL(string: urlStr) else { continue }
            let client = WebSocketClient()
            client.isTemporary = true
            client.$connectionState
                .receive(on: DispatchQueue.main)
                .sink { state in
                    if state == .connected {
                        client.send(text: str)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            client.disconnect()
                        }
                    }
                }
                .store(in: &cancellables)
            client.connect(url: url)
        }
    }

    /// Reports an event using Kind 1984
    /// - Parameters:
    ///   - eventId: The ID of the event being reported
    ///   - pubkey: The pubkey of the event author
    ///   - reason: Short reason for reporting (e.g., "spam", "illegal")
    ///   - description: Optional additional details
    func reportEvent(eventId: String, pubkey: String, reason: String, description: String? = nil) {
        var tags = [
            ["e", eventId, "", "report"],
            ["p", pubkey]
        ]

        // Add reason-specific tag if provided
        if !reason.isEmpty {
            tags.append(["reason", reason])
        }

        guard let signed = signEvent(kind: 1984, content: description ?? "Reported for \(reason)", tags: tags) else {
            print("NostrService: Failed to sign reporting event")
            return
        }

        postEvent(signed)
        #if DEBUG
        print("NostrService: Posted Kind 1984 report for event \(eventId)")
        #endif
    }

    /// Reports a user using Kind 1984
    /// - Parameters:
    ///   - pubkey: The pubkey of the user being reported
    ///   - reason: Short reason for reporting (e.g., "spam", "illegal")
    ///   - description: Optional additional details
    func reportUser(pubkey: String, reason: String, description: String? = nil) {
        var tags = [
            ["p", pubkey]
        ]

        if !reason.isEmpty {
            tags.append(["reason", reason])
        }

        guard let signed = signEvent(kind: 1984, content: description ?? "Reported user for \(reason)", tags: tags) else {
            print("NostrService: Failed to sign user reporting event")
            return
        }

        postEvent(signed)
        #if DEBUG
        print("NostrService: Posted Kind 1984 report for user \(pubkey)")
        #endif
    }

    /// Publishes a NIP-09 deletion request (kind 5) for the given event ID
    func deleteNote(id: String) {
        guard let signed = signEvent(kind: 5, content: "", tags: [["e", id]]) else {
            print("NostrService: Failed to sign deletion event")
            return
        }
        postEvent(signed)
        #if DEBUG
        print("NostrService: Posted Kind 5 deletion request for event \(id)")
        #endif
    }

    // Per-relay reconnection state to implement exponential backoff
    private var relayReconnectAttempts: [String: Int] = [:]
    private var relayLastReconnectTime: [String: Date] = [:]
    private let maxReconnectAttempts = 10
    private let baseReconnectDelay: TimeInterval = 2.0
    private let maxReconnectDelay: TimeInterval = 30.0  // Cap at 30s instead of 60s to reduce freeze perception

    /// Adds 0-2s random jitter to prevent all clients reconnecting simultaneously after a network drop
    private func delayWithJitter(attempts: Int) -> TimeInterval {
        let base = min(baseReconnectDelay * pow(2.0, Double(attempts)), maxReconnectDelay)
        let jitter = Double.random(in: 0...2.0)
        return base + jitter
    }

    // Check if URL is the local relay
    private func isLocalRelay(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        let port = url.port ?? 80
        return host == "localhost" || host == "127.0.0.1" || host == "0.0.0.0" ||
               (host == "127.0.0.1" && port == 3355) ||
               (host == "localhost" && port == 3355)
    }

    // Check if local relay is ready (not booting)
    private var isLocalRelayReady: Bool {
        // Check if relay manager says it's running AND not booting
        return RelayProcessManager.shared.isRunning && !RelayProcessManager.shared.isBooting
    }

    func fetchNotes(from relayURLs: [URL], until: Int64? = nil, authors: [String]? = nil) {
        DispatchQueue.main.async {
            self.isFetching = true
            self.activeSubscriptionCount = relayURLs.count
        }
        for url in relayURLs {
            let urlString = url.absoluteString

            // Skip local relay if it's still booting - prevents connection spam during boot
            // This guard is critical: prevents 10-second timeout freezes during relay boot
            if isLocalRelay(url) && !isLocalRelayReady {
                #if DEBUG
                if shouldLogConnect() {
                    print("NostrService: Skipping local relay - RelayProcessManager not ready (isRunning=\(RelayProcessManager.shared.isRunning), isBooting=\(RelayProcessManager.shared.isBooting))")
                }
                #endif
                continue
            }

            if let existing = clients[urlString] {
                if existing.connectionState == .connected {
                    sendRequest(to: existing, url: url, until: until, authors: authors)
                    continue
                } else if existing.connectionState == .connecting {
                    continue
                }
            }

            // Check if we should delay reconnect (exponential backoff)
            if let lastAttempt = relayLastReconnectTime[urlString],
               let attempts = relayReconnectAttempts[urlString] {
                let delay = delayWithJitter(attempts: attempts)
                let timeSinceLastAttempt = Date().timeIntervalSince(lastAttempt)

                if timeSinceLastAttempt < delay {
                    #if DEBUG
                    print("NostrService: Skipping reconnect to \(urlString) - backing off (\(attempts) attempts, \(delay - timeSinceLastAttempt)s remaining)")
                    #endif
                    // Schedule retry after backoff delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + (delay - timeSinceLastAttempt)) { [weak self] in
                        guard let self = self else { return }
                        guard self.clients[urlString] != nil else { return }
                        self.fetchNotes(from: [url], until: until, authors: authors)
                    }
                    continue
                }
            }

            let client = WebSocketClient()
            clients[urlString] = client

            client.messageSubject
                .receive(on: processingQueue)
                .sink { [weak self] message in
                    self?.processMessage(message, from: urlString)
                }
                .store(in: &cancellables)

            client.$connectionState
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak client] state in
                    guard let self = self else { return }
                    self.updateAggregatedStatus()
                    if state == .connected {
                        // Reset backoff on successful connection
                        self.relayReconnectAttempts[urlString] = 0
                        self.sendRequest(to: client!, url: url, until: until, authors: authors)
                    } else if state == .error {
                        // Increment backoff counter
                        let attempts = (self.relayReconnectAttempts[urlString] ?? 0) + 1
                        self.relayReconnectAttempts[urlString] = attempts
                        self.relayLastReconnectTime[urlString] = Date()

                        // Check if we've exceeded max attempts - stop hammering
                        if attempts > self.maxReconnectAttempts {
                            #if DEBUG
                            print("NostrService: Max reconnect attempts reached for \(urlString), giving up")
                            #endif
                            return
                        }

                        // Calculate exponential backoff delay with jitter
                        let delay = self.delayWithJitter(attempts: attempts - 1)

                        #if DEBUG
                        print("NostrService: Reconnecting to \(urlString) in \(delay)s (attempt \(attempts)/\(self.maxReconnectAttempts))")
                        #endif

                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                            guard let self = self else { return }
                            guard self.clients[urlString] != nil else { return }
                            self.fetchNotes(from: [url], until: until, authors: authors)
                        }
                    }
                }
                .store(in: &cancellables)

            client.connect(url: url)
        }
    }


    private func sendRequest(to client: WebSocketClient, url: URL, until: Int64? = nil, authors: [String]? = nil) {
        let urlString = url.absoluteString
        let isHistorical = until != nil

        let context = url.lastPathComponent.isEmpty ? "root" : url.lastPathComponent
        let subscriptionId: String

        if isHistorical {
            // Unique ID for pagination
            subscriptionId = "viewer-\(context)-hist-\(UUID().uuidString.prefix(4))"
        } else {
            // Stable ID for live feed
            subscriptionId = "viewer-\(context)-live"

            // Close previous live subscription if it's different (shouldn't happen with stable names, but safer)
            if let oldId = activeSubscriptions[urlString], oldId != subscriptionId {
                let closeMsg = ["CLOSE", oldId] as [Any]
                if let closeData = try? JSONSerialization.data(withJSONObject: closeMsg),
                   let closeStr = String(data: closeData, encoding: .utf8) {
                    client.send(text: closeStr)
                }
            }
            activeSubscriptions[urlString] = subscriptionId
        }

        var filter: [String: Any] = [
            "limit": isHistorical ? 100 : 200,
            "kinds": [0, 1, 3, 4, 6, 7, 1063, 30023, 9735, 10000]
        ]
        if let until = until {
            filter["until"] = until
        }

        // If we have followed authors, we fetch their notes
        var filters: [[String: Any]] = [filter]
        if let authors = authors, !authors.isEmpty {
            filters[0]["authors"] = authors
        }

        // CRITICAL: Always subscribe to mentions (#p) of the owner so "tagged notes"
        // from people we don't follow still show up in the viewer.
        let ownerHex = self.activeHexPubkey
        if !ownerHex.isEmpty {
            var mentionsFilter = filter
            mentionsFilter["#p"] = [ownerHex]
            filters.append(mentionsFilter)
        }

        let req = ["REQ", subscriptionId] + filters
        if let reqData = try? JSONSerialization.data(withJSONObject: req),
           let reqString = String(data: reqData, encoding: .utf8) {
            #if DEBUG
            print("NostrService: Sending REQ (\(subscriptionId)) with \(filters.count) filters to \(url.absoluteString)")
            #endif
            client.send(text: reqString)
        }
    }


    private func updateAggregatedStatus() {
        let states = clients.values.map { $0.connectionState }
        if states.contains(.connected) {
            connectionStatus = "Connected"
            connectionColor = "green"
        } else if states.contains(.connecting) {
            connectionStatus = "Connecting..."
            connectionColor = "yellow"
        } else if states.contains(.error) {
            connectionStatus = "Connection Error"
            connectionColor = "red"
        } else {
            connectionStatus = "Disconnected"
            connectionColor = "gray"
        }
    }

    private func processMessage(_ message: String, from urlString: String) {
        guard let data = message.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              json.count >= 2,
              let type = json[0] as? String else {
            return
        }

        if type == "EOSE", let subId = json[1] as? String {
            // Close historical subscriptions immediately after EOSE
            if subId.contains("-hist-") {
                let closeMsg = ["CLOSE", subId] as [Any]
                if let closeData = try? JSONSerialization.data(withJSONObject: closeMsg),
                   let closeStr = String(data: closeData, encoding: .utf8),
                   let client = clients[urlString] {
                    client.send(text: closeStr)
                    #if DEBUG
                    print("NostrService: Closed historical subscription \(subId)")
                    #endif
                }
            }

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                // Flush any buffered events before marking EOSE complete
                self.flushEventBuffer()
                self.activeSubscriptionCount -= 1
                if self.activeSubscriptionCount <= 0 {
                    self.isFetching = false
                    self.activeSubscriptionCount = 0
                }
                self.events.sort(by: { $0.created_at > $1.created_at })
                self.eventUpdateSubject.send()
            }
        }

        if type != "EVENT" { return }

        guard json.count >= 3 else { return }

        if let eventDict = json[2] as? [String: Any],
           let eventData = try? JSONSerialization.data(withJSONObject: eventDict),
           let event = try? JSONDecoder().decode(NostrEvent.self, from: eventData) {

            if event.kind == 0 {
                // Handling Kind 0 (Metadata)
                if let metadata = try? JSONSerialization.jsonObject(with: event.content.data(using: .utf8) ?? Data()) as? [String: Any] {
                    let name = metadata["name"] as? String
                    let displayName = metadata["display_name"] as? String
                    let picture = (metadata["picture"] as? String).flatMap { URL(string: $0) }
                    let nip05 = metadata["nip05"] as? String
                    let about = metadata["about"] as? String
                    let lud16 = metadata["lud16"] as? String
                    let lud06 = metadata["lud06"] as? String
                    let website = metadata["website"] as? String

                    DispatchQueue.main.async { [weak self] in
                        guard let self = self else { return }
                        var profile = self.profiles[event.pubkey] ?? FeedProfile(pubkey: event.pubkey)

                        var changed = false
                        if profile.name != name {
                            profile.name = name
                            changed = true
                        }
                        if profile.displayName != displayName {
                            profile.displayName = displayName
                            changed = true
                        }
                        if profile.pictureURL != picture {
                            profile.pictureURL = picture
                            changed = true
                        }
                        if profile.nip05 != nip05 {
                            profile.nip05 = nip05
                            changed = true
                        }
                        if profile.about != about {
                            profile.about = about
                            changed = true
                        }
                        if profile.lud16 != lud16 {
                            profile.lud16 = lud16
                            changed = true
                        }
                        if profile.lud06 != lud06 {
                            profile.lud06 = lud06
                            changed = true
                        }
                        if profile.website != website {
                            profile.website = website
                            changed = true
                        }

                        if changed {
                            self.profiles[event.pubkey] = profile
                            self.profilesInFlight.remove(event.pubkey)
                            self.saveProfilesThrottled()
                            self.eventUpdateSubject.send()
                        }
                    }
                }
                return // Metadata doesn't need to be in the events list
            }

            if event.kind == 10002 {
                // NIP-65: ["r", relay_url, "read" | "write"], no marker = both
                var inboxRelays: [String] = []
                for tag in event.tags {
                    if tag.count >= 2 && tag[0] == "r" {
                        let type = tag.count >= 3 ? tag[2] : ""
                        if type == "read" || type == "" {
                            inboxRelays.append(tag[1])
                        }
                    }
                }

                let pubkey = event.pubkey
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    if !inboxRelays.isEmpty {
                        self.relayLists[pubkey] = inboxRelays
                    }
                    self.relaysInFlight.remove(pubkey)
                    self.saveProfilesThrottled()
                }
                return
            }

            if event.kind == 10000 {
                // Parse Kind 10000 (Mute List)
                var blockedHexKeys: [String] = []
                for tag in event.tags {
                    if tag.count >= 2 && tag[0] == "p" {
                        blockedHexKeys.append(tag[1])
                    }
                }
                
                // Find which of our accounts matches this event's pubkey
                let allNpubs = ConfigService.shared.allAccountNpubs
                if let matchingNpub = allNpubs.first(where: { npub in
                    Bech32.decode(npub)?.hexString == event.pubkey
                }) {
                    // Map hex keys to npubs
                    let blockedNpubs = blockedHexKeys.compactMap { hexKey -> String? in
                        guard let data = Bech32.hexToData(hexKey) else { return nil }
                        return Bech32.encode(hrp: "npub", data: data)
                    }
                    
                    DispatchQueue.main.async {
                        let currentBlocks = ConfigService.shared.config.blockedNpubsPerAccount[matchingNpub] ?? []
                        let lastSync = ConfigService.shared.config.blockedNpubsLastSyncTimestamp[matchingNpub] ?? 0
                        
                        if event.created_at >= lastSync && Set(currentBlocks) != Set(blockedNpubs) {
                            ConfigService.shared.config.blockedNpubsPerAccount[matchingNpub] = blockedNpubs
                            ConfigService.shared.config.blockedNpubsLastSyncTimestamp[matchingNpub] = event.created_at
                            
                            // If this is the owner's account, sync to Go relay's blacklistedNpubs and save
                            if matchingNpub == ConfigService.shared.config.ownerNpub {
                                ConfigService.shared.config.blacklistedNpubs = blockedNpubs
                            }
                            
                            ConfigService.shared.save()
                            
                            #if DEBUG
                            print("NostrService: Synced \(blockedNpubs.count) blocks from Kind 10000 for \(matchingNpub.prefix(8))")
                            #endif
                            
                            NotificationCenter.default.post(name: NSNotification.Name("BlockedAccountsUpdated"), object: nil)
                        }
                    }
                }
                return
            }

            if seenEventIds.contains(event.id) { return }
            seenEventIds.insert(event.id)

            var items: [MediaItem] = []

            if event.kind == 1063 {
                // Parse KIND 1063 — NIP-94 file metadata with "url" and "m" (mime) tags
                if let urlTag = event.tags.first(where: { $0.count >= 2 && $0[0] == "url" }),
                   let url = URL(string: urlTag[1]) {
                    let mimeTag = event.tags.first(where: { $0.count >= 2 && $0[0] == "m" })?[1]
                    let mime = mimeTag ?? Self.mimeFromExtension(url)
                    let mediaType = Self.mediaTypeFromMime(mime, url: url)
                    items.append(MediaItem(id: UUID(), url: url, type: mediaType, dateAdded: event.createdAtDate, pubkey: event.pubkey, tags: event.tags, mimeType: mime))
                }
            } else {
                let urls = extractMediaURLs(from: event.content)
                items = urls.map { url in
                    let mime = Self.mimeFromExtension(url)
                    let mediaType = Self.mediaTypeFromMime(mime, url: url)
                    return MediaItem(id: UUID(), url: url, type: mediaType, dateAdded: event.createdAtDate, pubkey: event.pubkey, tags: event.tags, mimeType: mime)
                }
            }

            // Buffer event instead of dispatching to main thread per-event
            bufferLock.lock()
            eventBuffer.append((event, items))
            bufferLock.unlock()
            scheduleBufferFlush()
        }
    }


    // MARK: - Batched Event Flushing

    private func scheduleBufferFlush() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.bufferFlushTimer == nil else { return }
            self.bufferFlushTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    self?.flushEventBuffer()
                }
            }
        }
    }

    private func flushEventBuffer() {
        bufferFlushTimer?.invalidate()
        bufferFlushTimer = nil

        bufferLock.lock()
        let batch = eventBuffer
        eventBuffer.removeAll()
        bufferLock.unlock()

        guard !batch.isEmpty else { return }

        var newEvents: [NostrEvent] = []
        for (event, items) in batch {
            newEvents.append(event)
            if !items.isEmpty {
                noteMedia.append(contentsOf: items)
            }
        }

        // Efficiently merge and sort
        events.append(contentsOf: newEvents)

        // Only sort if we have a significant number of new events or the list is out of order
        // This is a trade-off: keep it snappy vs perfectly sorted at all times.
        if events.count > 1 {
            events.sort(by: { $0.created_at > $1.created_at })
        }

        if events.count > 10000 {
            events = Array(events.prefix(10000))
        }
        eventUpdateSubject.send()
    }

    /// Inject an externally-received event into the shared events array.
    /// Used by FeedService to forward zap receipts (Kind 9735) so the Viewer can display them.
    func injectEvent(_ event: NostrEvent) {
        guard !seenEventIds.contains(event.id) else { return }
        seenEventIds.insert(event.id)
        bufferLock.lock()
        eventBuffer.append((event, []))
        bufferLock.unlock()
        scheduleBufferFlush()
    }

    /// Fetch specific events by their IDs from the given relays.
    /// Results are merged into the shared `events` array via the normal processing pipeline.
    func fetchNotesByIds(_ ids: [String], from relayURLs: [URL]) {
        guard !ids.isEmpty else { return }

        let filter: [String: Any] = ["ids": ids]

        for url in relayURLs {
            let urlString = url.absoluteString
            if isLocalRelay(url) && !isLocalRelayReady { continue }

            // Reuse existing connected client if available
            if let existing = clients[urlString], existing.connectionState == .connected {
                let subId = "byid-\(UUID().uuidString.prefix(6))"
                let req = ["REQ", subId, filter] as [Any]
                if let data = try? JSONSerialization.data(withJSONObject: req),
                   let str = String(data: data, encoding: .utf8) {
                    existing.send(text: str)
                }
                continue
            }

            let client = WebSocketClient()
            client.isTemporary = true
            client.messageSubject
                .receive(on: processingQueue)
                .sink { [weak self] message in
                    self?.processMessage(message, from: urlString)
                }
                .store(in: &cancellables)

            let safeFilter = UncheckedSendable(value: filter)
            client.$connectionState
                .first(where: { $0 == .connected })
                .receive(on: DispatchQueue.main)
                .sink { [weak client] _ in
                    guard let client = client else { return }
                    let subId = "byid-\(UUID().uuidString.prefix(6))"
                    let req = ["REQ", subId, safeFilter.value] as [Any]
                    if let data = try? JSONSerialization.data(withJSONObject: req),
                       let str = String(data: data, encoding: .utf8) {
                        client.send(text: str)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                        client.disconnect()
                    }
                }
                .store(in: &cancellables)

            client.connect(url: url)
        }
    }

    func fetchCount(from relayURLs: [URL], filter: [String: Any] = [:]) async -> Int? {
        #if DEBUG
        print("NostrService: Starting aggregate fetchCount for \(relayURLs.count) relays")
        #endif
        var totalCount: Int? = nil

        let safeFilter = UncheckedSendable(value: filter)

        await withTaskGroup(of: Int?.self) { group in
            for url in relayURLs {
                group.addTask {
                    let filter = safeFilter.value
                    let urlString = url.absoluteString
                    let relayTag = url.lastPathComponent.isEmpty ? "outbox" : url.lastPathComponent

                    #if DEBUG
                    print("NostrService [\(relayTag)]: Task started")
                    #endif

                    let (client, isNew) = await MainActor.run { () -> (WebSocketClient?, Bool) in
                        if let existing = self.clients[urlString] {
                            #if DEBUG
                            print("NostrService [\(relayTag)]: Using existing client")
                            #endif
                            return (existing, false)
                        } else {
                            #if DEBUG
                            print("NostrService [\(relayTag)]: Creating new client")
                            #endif
                            let newClient = WebSocketClient()
                            newClient.isTemporary = true
                            return (newClient, true)
                        }
                    }

                    guard let client = client else {
                        #if DEBUG
                        print("NostrService [\(relayTag)]: Failed to get client")
                        #endif
                        return nil
                    }

                    // 1. Wait for connection if needed
                    if client.connectionState != .connected {
                        #if DEBUG
                        print("NostrService [\(relayTag)]: Not connected. Connecting now...")
                        #endif
                        client.connect(url: url)

                        var cancellable: AnyCancellable?
                        let didConnect = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                            var hasResumed = false

                            cancellable = client.$connectionState
                                .first(where: { $0 == .connected || $0 == .error })
                                .timeout(.seconds(5), scheduler: DispatchQueue.main)
                                .sink { completion in
                                    if !hasResumed {
                                        hasResumed = true
                                        if case .failure = completion {
                                            #if DEBUG
                                            print("NostrService [\(relayTag)]: Connection timeout")
                                            #endif
                                        }
                                        continuation.resume(returning: false)
                                    }
                                } receiveValue: { state in
                                    if !hasResumed {
                                        hasResumed = true
                                        #if DEBUG
                                        print("NostrService [\(relayTag)]: Connection state reached: \(state)")
                                        #endif
                                        continuation.resume(returning: state == .connected)
                                    }
                                }
                        }
                        _ = cancellable // Hold it until await finishes

                        if !didConnect {
                            #if DEBUG
                            print("NostrService [\(relayTag)]: Failed to connect during fetchCount")
                            #endif
                            if isNew { await MainActor.run { client.disconnect() } }
                            return nil
                        }
                    }

                    // 2. Send COUNT and wait for response
                    let subscriptionId = "count-\(UUID().uuidString.prefix(6))"
                    #if DEBUG
                    print("NostrService [\(relayTag)]: Sending COUNT with subId: \(subscriptionId)")
                    #endif

                    var messageCancellable: AnyCancellable?
                    let countResult = await withCheckedContinuation { (continuation: CheckedContinuation<Int?, Never>) in
                        var hasResumed = false

                        messageCancellable = client.messageSubject
                            .timeout(.seconds(10), scheduler: DispatchQueue.main)
                            .sink { completion in
                                if !hasResumed {
                                    hasResumed = true
                                    #if DEBUG
                                    print("NostrService [\(relayTag)]: COUNT response timeout or completion")
                                    #endif
                                    continuation.resume(returning: nil)
                                }
                            } receiveValue: { msg in
                                guard let data = msg.data(using: .utf8),
                                      let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
                                      json.count >= 3,
                                      let type = json[0] as? String,
                                      let subId = json[1] as? String,
                                      subId == subscriptionId else {
                                    return
                                }

                                if type == "COUNT" {
                                    if let payload = json[2] as? [String: Any],
                                       let rawCount = payload["count"] {
                                        let extractedCount: Int
                                        if let intVal = rawCount as? Int {
                                            extractedCount = intVal
                                        } else if let doubleVal = rawCount as? Double {
                                            extractedCount = Int(doubleVal)
                                        } else if let numberVal = rawCount as? NSNumber {
                                            extractedCount = numberVal.intValue
                                        } else if let stringVal = rawCount as? String, let intVal = Int(stringVal) {
                                            extractedCount = intVal
                                        } else {
                                            extractedCount = 0
                                        }
                                        
                                        if !hasResumed {
                                            hasResumed = true
                                            #if DEBUG
                                            print("NostrService [\(relayTag)]: Received COUNT, count: \(extractedCount)")
                                            #endif
                                            continuation.resume(returning: extractedCount)
                                        }
                                    }
                                }
                            }

                        // Send the actual COUNT request
                        let req = ["COUNT", subscriptionId, filter] as [Any]
                        if let reqData = try? JSONSerialization.data(withJSONObject: req),
                           let reqString = String(data: reqData, encoding: .utf8) {
                            client.send(text: reqString)
                        } else {
                            if !hasResumed {
                                hasResumed = true
                                continuation.resume(returning: nil)
                            }
                        }
                    }
                    _ = messageCancellable // Hold it until await finishes

                    if isNew {
                        #if DEBUG
                        print("NostrService [\(relayTag)]: Disconnecting temporary client")
                        #endif
                        await MainActor.run { client.disconnect() }
                    }

                    #if DEBUG
                    print("NostrService [\(relayTag)]: Returning count: \(String(describing: countResult))")
                    #endif
                    return countResult
                }
            }

            for await count in group {
                if let count = count {
                     totalCount = (totalCount ?? 0) + count
                }
            }
        }

        #if DEBUG
        print("NostrService: Final aggregated count: \(String(describing: totalCount))")
        #endif
        return totalCount
    }

    static func mimeFromExtension(_ url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        case "tiff", "tif": return "image/tiff"
        case "svg": return "image/svg+xml"
        case "mp4": return "video/mp4"
        case "hevc", "h265": return "video/mp4"
        case "mov": return "video/quicktime"
        case "webm": return "video/webm"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "m4a", "aac": return "audio/mp4"
        case "flac": return "audio/flac"
        case "ogg": return "audio/ogg"
        default: return nil
        }
    }

    nonisolated static func mediaTypeFromMime(_ mime: String?, url: URL) -> MediaItem.MediaType {
        if let mime = mime?.lowercased() {
            if mime.hasPrefix("video/") { return .video }
            if mime.hasPrefix("audio/") { return .audio }
            if mime.hasPrefix("image/") { return .image }
            if mime != "application/octet-stream" { return .unknown }
        }
        // Fallback to extension-based detection
        if url.isVideo { return .video }
        if url.isAudio { return .audio }
        return .image
    }

    /// Sniff the first 64 bytes of a remote URL via HTTP Range request to detect mime type.
    /// Returns (resolvedMime, mediaType) or nil if the request fails.
    nonisolated static func sniffRemoteMime(url: URL, rpm: RelayProcessManager) -> (mime: String, type: MediaItem.MediaType)? {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("bytes=0-63", forHTTPHeaderField: "Range")
        request.timeoutInterval = 5

        let semaphore = DispatchSemaphore(value: 0)
        var resultMime: String?

        // Use a session that ignores TLS errors for localhost
        let session = TLSSkipSession.shared
        let task = session.dataTask(with: request) { data, _, _ in
            if let data = data, data.count >= 4 {
                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try? data.write(to: tempURL)
                let detected = rpm.detectMimeFromBytes(for: tempURL)
                try? FileManager.default.removeItem(at: tempURL)
                if detected != "application/octet-stream" {
                    resultMime = detected
                }
            }
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 6)

        guard let mime = resultMime else { return nil }
        let type = mediaTypeFromMime(mime, url: url)
        return (mime, type)
    }

    func extractMediaURLs(from content: String) -> [URL] {
        let pattern = #"(https?://\S+?\.(?:jpg|jpeg|png|gif|webp|mp4|mov|webm|heic|tiff|hevc|h265)(?:\?\S+)?)|(https?://\S+?/blossom/[a-f0-9]{64})|(https?://\S+?/[a-f0-9]{64})"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        let nsString = content as NSString
        let results = regex.matches(in: content, options: [], range: NSRange(location: 0, length: nsString.length))

        var urls: [URL] = []
        for result in results {
            let urlString = nsString.substring(with: result.range)
            if let url = URL(string: urlString) {
                urls.append(url)
            }
        }

        return urls.map { url in
            var finalURL = url

            // Normalize potential local/development URLs to use HTTP instead of HTTPS
            // We check for localhost, 127.0.0.1, and any URL that matches the current relayURL if it's local
            let isKnownLocal = finalURL.host == "localhost" ||
                               finalURL.host == "127.0.0.1" ||
                               ConfigService.shared.config.isLocal

            if finalURL.scheme == "https" && isKnownLocal {
                var components = URLComponents(url: finalURL, resolvingAgainstBaseURL: false)
                components?.scheme = "http"
                if let normalizedURL = components?.url {
                    finalURL = normalizedURL
                }
            }
            return finalURL
        }
    }
}
