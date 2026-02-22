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

    var mediaURLs: [URL] {
        let pattern = #"https?://\S+?\.(?:jpg|jpeg|png|gif|webp|mp4|mov|webm|heic)(?:\?\S+)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        let ns = content as NSString
        return regex.matches(in: content, range: NSRange(location: 0, length: ns.length))
            .compactMap { URL(string: ns.substring(with: $0.range)) }
    }
}

struct FeedProfile {
    let pubkey: String
    var name: String?
    var displayName: String?
    var pictureURL: URL?
    var nip05: String?

    var bestName: String {
        if let d = displayName, !d.isEmpty { return d }
        if let n = name, !n.isEmpty { return n }
        return "npub…" + String(pubkey.suffix(6))
    }
}

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
    @Published var profiles: [String: FeedProfile] = [:]
    @Published var followedPubkeys: [String] = []
    @Published var isLoadingContacts = false
    @Published var isLoadingFeed    = false
    @Published var connectionStatus = "Disconnected"
    @Published var newNoteCount: Int = 0

    // One client per relay URL
    private var feedClients: [String: WebSocketClient] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var seenIds = Set<String>()
    private var newSinceLastView = Date()
    private var eoseCount = 0   // track when all relays return EOSE

    private var localRelayURL: URL? {
        URL(string: ConfigService.shared.config.nostrURL)
    }

    /// Public relays used to supplement the local relay.
    /// Uses Blastr relays if configured, otherwise well-known defaults.
    private var externalRelayURLs: [URL] {
        let configured = ConfigService.shared.config.blastrRelays
        let strs = configured.isEmpty ? [
            "wss://relay.damus.io",
            "wss://relay.primal.net",
            "wss://nos.lol",
        ] : configured
        return strs.prefix(3).compactMap { URL(string: $0) }
    }

    private init() {}

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

    func insertNote(_ note: FeedNote) {
        guard !seenIds.contains(note.id) else { return }
        seenIds.insert(note.id)
        if let idx = notes.firstIndex(where: { $0.createdAt < note.createdAt }) {
            notes.insert(note, at: idx)
        } else {
            notes.append(note)
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
                self?.followedPubkeys = pubkeys
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
            .receive(on: DispatchQueue.main)
            .sink { [weak self] msg in self?.handleFeedMsg(msg, totalRelays: totalRelays) }
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
            .receive(on: DispatchQueue.main)
            .sink { [weak self] msg in self?.handleFeedMsg(msg, totalRelays: totalRelays) }
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
            "kinds": [1, 6, 30023],
            "authors": followedPubkeys,
            "since": since,
            "limit": 200
        ]
        if let until = until { filter["until"] = until }
        let subId = "feed-\(label.suffix(8).filter { $0.isLetter || $0.isNumber })"
        let req = ["REQ", subId, filter] as [Any]
        if let data = try? JSONSerialization.data(withJSONObject: req),
           let str = String(data: data, encoding: .utf8) {
            client.send(text: str)
        }
    }

    private func handleFeedMsg(_ msg: String, totalRelays: Int) {
        guard let data = msg.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let type = json[0] as? String else { return }

        if type == "EOSE" {
            eoseCount += 1
            if eoseCount >= totalRelays {
                isLoadingFeed = false
                connectionStatus = "Live"
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
              let tags      = ev["tags"]        as? [[String]],
              !seenIds.contains(id) else { return }

        seenIds.insert(id)

        let note = FeedNote(
            id: id,
            pubkey: pubkey,
            content: content,
            createdAt: Date(timeIntervalSince1970: TimeInterval(createdAt)),
            tags: tags,
            kind: kind
        )

        if let idx = notes.firstIndex(where: { $0.createdAt < note.createdAt }) {
            notes.insert(note, at: idx)
        } else {
            notes.append(note)
        }
        if note.createdAt > newSinceLastView {
            newNoteCount += 1
        }
        if profiles[pubkey] == nil {
            fetchProfile(for: pubkey)
        }
    }

    // MARK: - Profile Fetch from local relay (falls back to external)

    private var fetchingProfiles = Set<String>()

    private func fetchProfile(for pubkey: String) {
        guard !fetchingProfiles.contains(pubkey) else { return }
        fetchingProfiles.insert(pubkey)
        profiles[pubkey] = FeedProfile(pubkey: pubkey)

        // Try local relay first, then first external relay
        let candidates: [URL] = ([localRelayURL] + [externalRelayURLs.first]).compactMap { $0 }
        fetchProfileFrom(candidates: candidates, pubkey: pubkey)
    }

    private func fetchProfileFrom(candidates: [URL], pubkey: String) {
        guard let url = candidates.first else { return }
        let remaining = Array(candidates.dropFirst())

        let c = WebSocketClient()
        c.isTemporary = true
        var got = false

        c.messageSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] msg in
                guard !got else { return }
                self?.handleProfileMsg(msg, pubkey: pubkey, client: c, onSuccess: { got = true })
            }
            .store(in: &cancellables)

        c.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { state in
                if state == .connected {
                    let filter: [String: Any] = ["kinds": [0], "authors": [pubkey], "limit": 1]
                    let req = ["REQ", "p-\(pubkey.prefix(6))", filter] as [Any]
                    if let data = try? JSONSerialization.data(withJSONObject: req),
                       let str = String(data: data, encoding: .utf8) {
                        c.send(text: str)
                    }
                } else if state == .error && !remaining.isEmpty && !got {
                    DispatchQueue.main.async { [weak self] in
                        self?.fetchProfileFrom(candidates: remaining, pubkey: pubkey)
                    }
                }
            }
            .store(in: &cancellables)

        c.connect(url: url)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            if !got && !remaining.isEmpty { self.fetchProfileFrom(candidates: remaining, pubkey: pubkey) }
            c.disconnect()
        }
    }

    private func handleProfileMsg(
        _ msg: String, pubkey: String, client: WebSocketClient, onSuccess: (() -> Void)? = nil
    ) {
        guard let data = msg.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let type = json[0] as? String, type == "EVENT",
              json.count >= 3,
              let ev = json[2] as? [String: Any],
              let kind = ev["kind"] as? Int, kind == 0,
              let contentStr = ev["content"] as? String,
              let metaData = contentStr.data(using: .utf8),
              let meta = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any]
        else { return }

        let profile = FeedProfile(
            pubkey: pubkey,
            name: meta["name"] as? String,
            displayName: meta["display_name"] as? String,
            pictureURL: (meta["picture"] as? String).flatMap { URL(string: $0) },
            nip05: meta["nip05"] as? String
        )
        profiles[pubkey] = profile
        onSuccess?()
        client.disconnect()
    }
}
