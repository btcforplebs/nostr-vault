import Foundation
import Combine

// MARK: - Models

struct FeedNote: Identifiable {
    let id: String
    let pubkey: String
    let content: String
    let createdAt: Date
    let tags: [[String]]
    let kind: Int

    var isReply: Bool {
        tags.contains { $0.count >= 2 && $0[0] == "e" }
    }

    var replyToPubkey: String? {
        tags.first { $0.count >= 2 && $0[0] == "p" }?[1]
    }

    var parentEventId: String? {
        tags.last { $0.count >= 2 && $0[0] == "e" }?[1]
    }

    var replyCount: Int {
        tags.filter { $0.count >= 2 && $0[0] == "e" }.count
    }

    var note1: String {
        guard let data = Bech32.hexToData(id) else { return id }
        return Bech32.encode(hrp: "note", data: data) ?? id
    }

    var nevent: String {
        guard let idData = Bech32.hexToData(id),
              let pubData = Bech32.hexToData(pubkey) else { return note1 }
        
        var tlv = Data()
        // Type 0: Event ID
        tlv.append(Bech32.encodeTLV(type: 0, data: idData))
        // Type 2: Author Pubkey
        tlv.append(Bech32.encodeTLV(type: 2, data: pubData))
        // Type 3: Kind
        let kindBytes = withUnsafeBytes(of: UInt32(kind).bigEndian) { Data($0) }
        tlv.append(Bech32.encodeTLV(type: 3, data: kindBytes))
        
        return Bech32.encode(hrp: "nevent", data: tlv) ?? note1
    }

    var mediaURLs: [URL] {
        let pattern = #"https?://\S+?\.(?:jpg|jpeg|png|gif|webp|mp4|mov|webm|heic)(?:\?\S+)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        let ns = content as NSString
        return regex.matches(in: content, range: NSRange(location: 0, length: ns.length))
            .compactMap { URL(string: ns.substring(with: $0.range)) }
    }
}

// MARK: - FeedService

// MARK: - FeedService

/// Builds a following feed by querying BOTH the local Haven relay and
/// well-known public Nostr relays in parallel.
/// - Local relay: fast, already has notes the inbox received from the network.
/// - External relays: fills in notes not yet mirrored to the local relay.
/// All results share a deduplication set so events never appear twice.
@MainActor
class FeedService: ObservableObject {
    static let shared = FeedService()

    @Published var notes: [FeedNote] = []
    @Published var followedPubkeys: [String] = []
    @Published var isLoadingContacts = false
    @Published var isLoadingFeed    = false
    @Published var connectionStatus = "Disconnected"
    @Published var newNoteCount: Int = 0
    @Published var likedEventIds: Set<String> = []

    // One client per relay URL
    private var feedClients: [String: WebSocketClient] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var seenIds = Set<String>()
    private var newSinceLastView = Date()
    private var eoseCount = 0   // track when all relays return EOSE

    // Background queue for JSON parsing — keeps the main thread free for UI
    private let processingQueue = DispatchQueue(label: "com.haven.feed-processing", qos: .userInitiated)

    private var localRelayURL: URL? {
        // Only include the local relay when it is confirmed running.
        // During boot (WoT initialization, ~3 min) the HTTP server may be
        // listening but not fully ready, causing WebSocket failures.
        guard RelayProcessManager.shared.isRunning,
              !RelayProcessManager.shared.isBooting else { return nil }
        return URL(string: ConfigService.shared.config.nostrURL)
    }

    /// Public relays used to supplement the local relay.
    /// Uses Blastr relays if configured, otherwise well-known defaults.
    private var externalRelayURLs: [URL] {
        let configured = ConfigService.shared.config.feedRelays
        let strs = configured.isEmpty ? [
            "wss://relay.damus.io",
            "wss://relay.primal.net",
            "wss://nos.lol",
        ] : configured
        return strs.compactMap { URL(string: $0) }
    }

    // Batched note buffer — avoids per-event @Published mutations
    private var noteBuffer: [FeedNote] = []
    private var noteFlushTimer: Timer?

    // Batched profile fetching — avoids per-pubkey WebSocket creation
    private var profileFetchQueue = Set<String>()
    private var profileFlushTimer: Timer?

    // Batched note fetching (e.g. for parent events in threads)
    private var fetchingNoteIds = Set<String>()
    private var noteFetchQueue  = Set<String>()
    private var noteFetchTimer: Timer?

    // Profile saving
    private var profileSaveTimer: Timer?

    private init() {
        // FeedService no longer manages profiles; NostrService does.
    }

    // MARK: - Public API

    func refresh() {
        guard !isLoadingContacts else { return }
        newNoteCount = 0
        newSinceLastView = Date()
        loadContactList { [weak self] in
            self?.subscribeToAllRelays()
        }
    }

    func markViewed() {
        newNoteCount = 0
        newSinceLastView = Date()
    }

    func addNote(_ note: FeedNote) {
        if !notes.contains(where: { $0.id == note.id }) {
            notes.insert(note, at: 0)
            seenIds.insert(note.id)
        }
    }

    /// Requests a fetch for a note that is missing from the local state.
    /// Used for resolving thread parents.
    func fetchMissingNote(id: String) {
        guard !seenIds.contains(id), !fetchingNoteIds.contains(id) else { return }
        fetchingNoteIds.insert(id)
        noteFetchQueue.insert(id)
        scheduleNoteFetchFlush()
    }

    /// Load older notes (pagination) — fetches the page before the oldest note currently shown.
    func loadMore() {
        guard !isLoadingFeed, let oldest = notes.last?.createdAt else { return }
        let until = Int64(oldest.timeIntervalSince1970) - 1
        guard !followedPubkeys.isEmpty else { return }

        isLoadingFeed = true
        eoseCount = 0

        var allURLs: [URL] = []
        if let local = localRelayURL { allURLs.append(local) }
        allURLs.append(contentsOf: externalRelayURLs)

        let totalRelays = allURLs.count
        for url in allURLs {
            connectFeedRelayWithUntil(url: url, until: until, totalRelays: totalRelays)
        }
    }

    func disconnect() {
        feedClients.values.forEach { $0.disconnect() }
        feedClients.removeAll()
        cancellables.removeAll()
        connectionStatus = "Disconnected"
    }

    // MARK: - Contact List (Kind 3)
    // Fetch the owner's follows from the local relay.
    // Falls back to a well-known public relay if not found locally.

    private func loadContactList(completion: @escaping () -> Void) {
        let ownerNpub = ConfigService.shared.config.ownerNpub
        guard !ownerNpub.isEmpty,
              let ownerHex = Bech32.decode(ownerNpub)?.hexString else {
            completion(); return
        }

        isLoadingContacts = true
        connectionStatus = "Fetching contact list…"

        // Try local relay first; if it returns empty, fall back to an external relay.
        let candidates: [URL] = ([localRelayURL] + externalRelayURLs).compactMap { $0 }
        tryFetchContactList(from: candidates, ownerHex: ownerHex, completion: completion)
    }

    private func tryFetchContactList(from relays: [URL], ownerHex: String, completion: @escaping () -> Void) {
        guard let url = relays.first else {
            isLoadingContacts = false; completion(); return
        }
        let remaining = Array(relays.dropFirst())

        let c = WebSocketClient()
        c.isTemporary = true

        c.messageSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] msg in
                self?.handleContactListMsg(
                    msg, ownerHex: ownerHex, client: c,
                    fallbackRelays: remaining, completion: completion
                )
            }
            .store(in: &cancellables)

        c.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { state in
                if state == .connected {
                    let filter: [String: Any] = ["kinds": [3], "authors": [ownerHex], "limit": 1]
                    let req = ["REQ", "cl-\(UUID().uuidString.prefix(4))", filter] as [Any]
                    if let data = try? JSONSerialization.data(withJSONObject: req),
                       let str = String(data: data, encoding: .utf8) {
                        c.send(text: str)
                    }
                } else if state == .error {
                    // Try next relay
                    DispatchQueue.main.async { [weak self] in
                        self?.tryFetchContactList(from: remaining, ownerHex: ownerHex, completion: completion)
                    }
                }
            }
            .store(in: &cancellables)

        c.connect(url: url)

        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard self?.isLoadingContacts == true else { return }
            c.disconnect()
            self?.tryFetchContactList(from: remaining, ownerHex: ownerHex, completion: completion)
        }
    }

    private func handleContactListMsg(
        _ msg: String, ownerHex: String, client: WebSocketClient,
        fallbackRelays: [URL] = [], completion: @escaping () -> Void
    ) {
        guard let data = msg.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let type = json[0] as? String else { return }

        if type == "EVENT", json.count >= 3,
           let eventDict = json[2] as? [String: Any],
           let kind = eventDict["kind"] as? Int, kind == 3,
           let tags = eventDict["tags"] as? [[String]] {

            let pubkeys = tags.compactMap { t -> String? in
                guard t.count >= 2, t[0] == "p" else { return nil }
                return t[1]
            }

            if pubkeys.isEmpty && !fallbackRelays.isEmpty {
                // No follows found on this relay — try next
                client.disconnect()
                DispatchQueue.main.async { [weak self] in
                    self?.tryFetchContactList(from: fallbackRelays, ownerHex: ownerHex, completion: completion)
                }
                return
            }

            DispatchQueue.main.async { [weak self] in
                var finalPubkeys = pubkeys
                if !finalPubkeys.contains(ownerHex) {
                    finalPubkeys.append(ownerHex)
                }
                self?.followedPubkeys = finalPubkeys
                self?.isLoadingContacts = false
                client.disconnect()
                self?.connectionStatus = pubkeys.isEmpty ? "No contacts found" : "Loaded \(pubkeys.count) contacts"
                completion()
            }
        } else if type == "EOSE" {
            DispatchQueue.main.async { [weak self] in
                self?.isLoadingContacts = false
                client.disconnect()
                // If still no pubkeys and have fallbacks, try them
                if self?.followedPubkeys.isEmpty == true && !fallbackRelays.isEmpty {
                    self?.tryFetchContactList(from: fallbackRelays, ownerHex: ownerHex, completion: completion)
                } else {
                    completion()
                }
            }
        }
    }

    // MARK: - Feed Subscription (local + external in parallel)

    private func subscribeToAllRelays() {
        guard !followedPubkeys.isEmpty else {
            connectionStatus = "Follow someone on Nostr to see their posts here"
            return
        }

        isLoadingFeed = true
        eoseCount = 0
        connectionStatus = "Loading feed…"

        // Disconnect existing feed clients
        feedClients.values.forEach { $0.disconnect() }
        feedClients.removeAll()

        // Build list: local relay first, then external
        var allURLs: [URL] = []
        if let local = localRelayURL { allURLs.append(local) }
        allURLs.append(contentsOf: externalRelayURLs)

        let totalRelays = allURLs.count
        for url in allURLs {
            connectFeedRelay(url: url, totalRelays: totalRelays)
        }
    }

    private func connectFeedRelay(url: URL, totalRelays: Int) {
        let key = url.absoluteString
        let c = WebSocketClient()
        feedClients[key] = c

        c.messageSubject
            .receive(on: processingQueue)
            .sink { [weak self] msg in self?.handleFeedMsgBackground(msg, totalRelays: totalRelays) }
            .store(in: &cancellables)

        c.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .connected:
                    self.sendFeedSubscription(client: c, label: key)
                case .error:
                    // Reconnect after delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                        guard self?.feedClients[key] === c else { return }
                        self?.connectFeedRelay(url: url, totalRelays: totalRelays)
                    }
                default: break
                }
            }
            .store(in: &cancellables)

        c.connect(url: url)
    }

    /// One-shot pagination client — opens, fetches until the given timestamp, then disconnects.
    private func connectFeedRelayWithUntil(url: URL, until: Int64, totalRelays: Int) {
        let key = "page-\(url.absoluteString)"
        let c = WebSocketClient()
        c.isTemporary = true
        feedClients[key] = c

        c.messageSubject
            .receive(on: processingQueue)
            .sink { [weak self] msg in self?.handleFeedMsgBackground(msg, totalRelays: totalRelays) }
            .store(in: &cancellables)

        c.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                if state == .connected {
                    self?.sendFeedSubscription(client: c, label: key, until: until)
                }
            }
            .store(in: &cancellables)

        c.connect(url: url)
    }

    private func sendFeedSubscription(client: WebSocketClient, label: String, until: Int64? = nil) {
        let since = Int64(Date().timeIntervalSince1970) - (30 * 24 * 3600) // last 30 days
        var filter: [String: Any] = [
            "kinds": [1, 6, 7, 30023],
            "authors": followedPubkeys,
            "since": since,
            "limit": 50
        ]
        if let until = until { filter["until"] = until }
        let subId = "feed-\(label.suffix(8).filter { $0.isLetter || $0.isNumber })"
        let req = ["REQ", subId, filter] as [Any]
        if let data = try? JSONSerialization.data(withJSONObject: req),
           let str = String(data: data, encoding: .utf8) {
            client.send(text: str)
        }
    }

    /// Called on processingQueue — parses JSON off the main thread, then dispatches results
    private nonisolated func handleFeedMsgBackground(_ msg: String, totalRelays: Int) {
        guard let data = msg.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let type = json[0] as? String else { return }

        if type == "EOSE" {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.eoseCount += 1
                if self.eoseCount >= totalRelays {
                    self.flushNoteBuffer()
                    self.isLoadingFeed = false
                    self.connectionStatus = "Live"
                }
            }
            return
        }

        guard type == "EVENT", json.count >= 3,
              let ev = json[2] as? [String: Any],
              let id        = ev["id"]         as? String,
              let pubkey    = ev["pubkey"]      as? String,
              let content   = ev["content"]     as? String,
              let createdAt = ev["created_at"]  as? Int64,
              let kind      = ev["kind"]        as? Int,
              let tags      = ev["tags"]        as? [[String]]
        else { return }

        // Handle Reactions (Kind 7)
        if kind == 7 {
            if let targetId = tags.first(where: { $0.count >= 2 && $0[0] == "e" })?[1] {
                DispatchQueue.main.async { [weak self] in
                    let ownerHex = NostrService.shared.ownerHexPubkey
                    if pubkey == ownerHex {
                        self?.likedEventIds.insert(targetId)
                    }
                }
            }
            return
        }

        var parsedContent = content
        var originalPubkey: String? = nil
        
        if kind == 6 {
            if let data = content.data(using: .utf8),
               let inner = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let innerContent = inner["content"] as? String {
                parsedContent = innerContent
                originalPubkey = inner["pubkey"] as? String
            } else {
                parsedContent = ""
            }
        }

        let note = FeedNote(
            id: id,
            pubkey: originalPubkey ?? pubkey,
            content: parsedContent,
            createdAt: Date(timeIntervalSince1970: TimeInterval(createdAt)),
            tags: tags,
            kind: kind
        )

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard !self.seenIds.contains(id) else { return }
            self.seenIds.insert(id)

            self.noteBuffer.append(note)
            self.scheduleNoteFlush()

            if NostrService.shared.profiles[pubkey] == nil {
                NostrService.shared.fetchMissingProfiles(for: [pubkey])
            }
            if let op = originalPubkey, NostrService.shared.profiles[op] == nil {
                NostrService.shared.fetchMissingProfiles(for: [op])
            }
        }
    }

    // MARK: - Batched Note Flushing

    private func scheduleNoteFlush() {
        guard noteFlushTimer == nil else { return }
        noteFlushTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.flushNoteBuffer()
            }
        }
    }

    private func flushNoteBuffer() {
        noteFlushTimer?.invalidate()
        noteFlushTimer = nil
        guard !noteBuffer.isEmpty else { return }

        let batch = noteBuffer
        noteBuffer.removeAll()

        // Count new notes before merging (excluding replies)
        let newCount = batch.filter { $0.createdAt > newSinceLastView && !$0.isReply }.count
        newNoteCount += newCount

        // O(n log n) merge instead of O(n²) per-note insertion
        notes.append(contentsOf: batch)
        notes.sort { $0.createdAt > $1.createdAt }
    }

    // MARK: - Note Fetching logic

    private func scheduleNoteFetchFlush() {
        guard noteFetchTimer == nil else { return }
        noteFetchTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.flushNoteFetchRequests()
            }
        }
    }

    private func flushNoteFetchRequests() {
        noteFetchTimer?.invalidate()
        noteFetchTimer = nil
        guard !noteFetchQueue.isEmpty else { return }

        let ids = Array(noteFetchQueue)
        noteFetchQueue.removeAll()

        let candidates: [URL] = ([localRelayURL] + externalRelayURLs).compactMap { $0 }
        
        #if DEBUG
        print("FeedService: Fetching \(ids.count) missing notes for threading")
        #endif

        for url in candidates {
            let c = WebSocketClient()
            c.isTemporary = true
            
            c.messageSubject
                .receive(on: processingQueue)
                .sink { [weak self] msg in
                    // Re-use background handler; totalRelays 1 is safe for temporary fetching
                    self?.handleFeedMsgBackground(msg, totalRelays: 1)
                }
                .store(in: &cancellables)

            c.$connectionState
                .receive(on: DispatchQueue.main)
                .sink { state in
                    if state == .connected {
                        let filter: [String: Any] = ["ids": ids]
                        let req = ["REQ", "tfetch-\(UUID().uuidString.prefix(6))", filter] as [Any]
                        if let data = try? JSONSerialization.data(withJSONObject: req),
                           let str = String(data: data, encoding: .utf8) {
                            c.send(text: str)
                        }
                        
                        // Self-destruct after delay
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                            c.disconnect()
                        }
                    }
                }
                .store(in: &cancellables)

            c.connect(url: url)
        }
    }
}
