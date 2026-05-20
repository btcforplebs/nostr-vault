import Foundation
import Combine
import SwiftUI

// MARK: - Models

/// Lightweight engagement counts per note, populated from relay data.
struct NoteStats {
    var replies: Int = 0
    var reactions: Int = 0
    var reposts: Int = 0
}

struct FeedNote: Identifiable {
    let id: String
    let pubkey: String
    let content: String
    let createdAt: Date
    let tags: [[String]]
    let kind: Int
    let repostedBy: String?

    // Cached at init to avoid recomputing on every SwiftUI render
    let isReply: Bool
    let replyToPubkey: String?
    let parentEventId: String?
    let mediaURLs: [URL]
    let quotedEventIds: [String]

    /// The event ID of the original note referenced by a kind 6 repost (from e-tags).
    let repostedEventId: String?

    init(id: String, pubkey: String, content: String, createdAt: Date, tags: [[String]], kind: Int, repostedBy: String? = nil) {
        self.id = id
        self.pubkey = pubkey
        self.content = content
        self.createdAt = createdAt
        self.tags = tags
        self.kind = kind
        self.repostedBy = repostedBy

        // Cache tag-derived properties
        let eTags = tags.filter { $0.count >= 2 && $0[0] == "e" }
        let nonMentionETags = eTags.filter { tag in
            guard tag.count >= 4 else { return true }
            return tag[3] != "mention"
        }
        // Kind 6 reposts have e-tags but are not replies
        self.isReply = kind != 6 && !nonMentionETags.isEmpty
        self.replyToPubkey = kind != 6 ? tags.first { $0.count >= 2 && $0[0] == "p" }?[1] : nil
        self.parentEventId = kind != 6 ? tags.last { $0.count >= 2 && $0[0] == "e" }?[1] : nil

        // For kind 6 reposts, capture the referenced event ID
        self.repostedEventId = kind == 6 ? eTags.first?[1] : nil

        // Cache regex-derived properties (expensive — only compute once)
        self.mediaURLs = Self.parseMediaURLs(from: content)
        self.quotedEventIds = Self.parseQuotedEventIds(from: content)
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
        tlv.append(Bech32.encodeTLV(type: 0, data: idData))
        tlv.append(Bech32.encodeTLV(type: 2, data: pubData))
        let kindBytes = withUnsafeBytes(of: UInt32(kind).bigEndian) { Data($0) }
        tlv.append(Bech32.encodeTLV(type: 3, data: kindBytes))

        return Bech32.encode(hrp: "nevent", data: tlv) ?? note1
    }

    // MARK: - Static parsers (called once at init)

    private static let mediaRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"https?://\S+?\.(?:jpg|jpeg|png|gif|webp|mp4|mov|webm|heic)(?:\?\S+)?"#, options: .caseInsensitive)
    }()

    private static let quoteRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"nostr:(note1[a-z0-9]+|nevent1[a-z0-9]+)"#, options: .caseInsensitive)
    }()

    private static func parseMediaURLs(from content: String) -> [URL] {
        guard let regex = mediaRegex else { return [] }
        let ns = content as NSString
        return regex.matches(in: content, range: NSRange(location: 0, length: ns.length))
            .compactMap { URL(string: ns.substring(with: $0.range)) }
    }

    private static func parseQuotedEventIds(from content: String) -> [String] {
        guard let regex = quoteRegex else { return [] }
        let ns = content as NSString
        return regex.matches(in: content, range: NSRange(location: 0, length: ns.length))
            .compactMap { match -> String? in
                let identifier = ns.substring(with: match.range(at: 1))
                if identifier.hasPrefix("note1") {
                    return Bech32.decode(identifier)?.hexString
                } else if identifier.hasPrefix("nevent1") {
                    guard let decoded = Bech32.decode(identifier) else { return nil }
                    var data = decoded.data
                    while data.count >= 2 {
                        let type = data.removeFirst()
                        let length = Int(data.removeFirst())
                        if data.count >= length {
                            let value = data.prefix(length)
                            if type == 0 && length == 32 {
                                return value.map { String(format: "%02x", $0) }.joined()
                            }
                            data.removeFirst(length)
                        } else {
                            break
                        }
                    }
                }
                return nil
            }
    }

    /// Technical heuristic to filter out spam, bots, empty, duplicate, or telemetry noise.
    static func isNoiseOrSpam(content: String, tags: [[String]]) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        
        // 1. JSON / technical payloads (common in spam/telemetry)
        if trimmed.hasPrefix("{") && trimmed.hasSuffix("}") {
            return true
        }
        
        let lower = trimmed.lowercased()
        if lower.contains("nostr-wallet-connect") ||
           lower.contains("\"method\":") ||
           lower.contains("\"result\":") ||
           lower.contains("nip47") {
            return true
        }
        
        // 2. Excessive consecutive repeated characters (e.g. spam lines or emoji flood)
        var consecutiveCount = 1
        var lastChar: Character? = nil
        for char in trimmed {
            if let last = lastChar, last == char {
                consecutiveCount += 1
                if consecutiveCount >= 20 {
                    return true
                }
            } else {
                consecutiveCount = 1
            }
            lastChar = char
        }
        
        // 3. Hashtag or Mention stuffing (in very short content)
        let hashtags = tags.filter { $0.count >= 2 && $0[0] == "t" }
        let mentions = tags.filter { $0.count >= 2 && $0[0] == "p" }
        if trimmed.count < 100 {
            if hashtags.count > 6 || mentions.count > 6 {
                return true
            }
        }
        
        // 4. Common bot status updates, advertising, or phishing
        let spamKeywords = [
            "relay status:", "relay uptime:", "ping time:", "block height:",
            "free bitcoin", "earn double bitcoin", "telegram channel for free",
            "pump telegram", "whatsapp group", "click here to claim"
        ]
        for keyword in spamKeywords {
            if lower.contains(keyword) {
                return true
            }
        }
        
        return false
    }
}

// MARK: - BackgroundAccumulator

/// Thread-safe buffer for events parsed off the main thread.
/// All methods must be called on the FeedService processingQueue.
final class BackgroundAccumulator: @unchecked Sendable {
    var notes: [FeedNote] = []
    var profiles: [String] = []
    /// Reaction events: (target note ID, reactor pubkey). Used for both self-like
    /// detection and per-note reaction counting.
    var reactionEvents: [(targetId: String, pubkey: String)] = []
    /// Parent note IDs that received a reply (from kind 1 events with e-tags).
    var replyTargets: [String] = []
    /// Note IDs that were reposted (from kind 6 events).
    var repostTargets: [String] = []
    var flushScheduled = false

    /// Dedup set for engagement events (reactions, etc.) to avoid double-counting
    /// from multiple relays. NOT drained — persists across flushes.
    var seenEngagementIds = Set<String>()
    private static let maxEngagementIds = 20_000

    static let flushInterval: TimeInterval = 0.5

    struct Snapshot {
        let notes: [FeedNote]
        let profiles: [String]
        let reactionEvents: [(targetId: String, pubkey: String)]
        let replyTargets: [String]
        let repostTargets: [String]
    }

    func drain() -> Snapshot {
        let snap = Snapshot(
            notes: notes,
            profiles: profiles,
            reactionEvents: reactionEvents,
            replyTargets: replyTargets,
            repostTargets: repostTargets
        )
        notes.removeAll(keepingCapacity: true)
        profiles.removeAll(keepingCapacity: true)
        reactionEvents.removeAll(keepingCapacity: true)
        replyTargets.removeAll(keepingCapacity: true)
        repostTargets.removeAll(keepingCapacity: true)
        flushScheduled = false

        // Cap dedup set to prevent unbounded growth
        if seenEngagementIds.count > Self.maxEngagementIds {
            seenEngagementIds.removeAll(keepingCapacity: true)
        }
        return snap
    }
}

// MARK: - FeedService

/// Feed mode: following (contacts only) or global (all notes from relays).
enum FeedMode: String, CaseIterable {
    case following = "Following"
    case global = "Global"
}

/// Builds a following feed by querying BOTH the local Haven relay and
/// well-known public Nostr relays in parallel.
/// - Local relay: fast, already has notes the inbox received from the network.
/// - External relays: fills in notes not yet mirrored to the local relay.
/// All results share a deduplication set so events never appear twice.
@MainActor
class FeedService: ObservableObject {
    static let shared = FeedService()

    @Published var feedMode: FeedMode = .following
    @Published var notes: [FeedNote] = []
    @Published var followedPubkeys: [String] = []
    @Published var isLoadingContacts = false
    @Published var isLoadingFeed    = false
    @Published var connectionStatus = "Disconnected"

    /// Three-state connection indicator color
    var connectionDotColor: Color {
        switch connectionStatus {
        case "Live":
            return Color(red: 0.2, green: 0.8, blue: 0.6) // Green
        case "Disconnected", "No contacts found":
            return Color.red.opacity(0.8) // Red
        default:
            return Color(red: 1, green: 0.6, blue: 0.1) // Orange (loading/connecting)
        }
    }
    @Published var newNoteCount: Int = 0
    @Published var pendingNotes: [FeedNote] = []
    @Published var likedEventIds: Set<String> = []
    @Published var zappedEventIds: [String: Int] = [:]
    @Published var onchainZapEventIds: [String: Int] = [:]
    /// Per-note engagement counts (replies, reactions, reposts) from relay data.
    @Published var noteStats: [String: NoteStats] = [:]

    // Preserve the original kind 3 content (relay hints) to avoid wiping it on follow/unfollow
    private var contactListContent: String = ""

    // One client per relay URL
    private var feedClients: [String: WebSocketClient] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var seenIds = Set<String>()
    private var newSinceLastView = Date()
    private var eoseCount = 0   // track when all relays return EOSE

    // Background queue for JSON parsing — keeps the main thread free for UI
    private let processingQueue = DispatchQueue(label: "com.haven.feed-processing", qos: .userInitiated)

    // Thread-safe accumulator for background event parsing → main thread delivery.
    // All access is serialized on processingQueue.
    private let bgAccumulator = BackgroundAccumulator()

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
        loadInteractionState()
    }

    // MARK: - Interaction State Persistence

    private static let interactionStateFile = "interaction_state.json"

    private var interactionSaveThrottle: Date = .distantPast

    private func loadInteractionState() {
        let url = Self.interactionStateURL()
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(InteractionState.self, from: data) else { return }
        self.likedEventIds = state.likedEventIds
        self.zappedEventIds = state.zappedEventIds
        self.onchainZapEventIds = state.onchainZapEventIds
        #if DEBUG
        print("FeedService: Loaded \(state.likedEventIds.count) likes, \(state.zappedEventIds.count) zaps, \(state.onchainZapEventIds.count) onchain zaps from disk")
        #endif
    }

    func saveInteractionState() {
        // Throttle saves to at most once per 2 seconds
        let now = Date()
        guard now.timeIntervalSince(interactionSaveThrottle) > 2.0 else { return }
        interactionSaveThrottle = now

        let state = InteractionState(likedEventIds: likedEventIds, zappedEventIds: zappedEventIds, onchainZapEventIds: onchainZapEventIds)
        let url = Self.interactionStateURL()
        DispatchQueue.global(qos: .utility).async {
            if let data = try? JSONEncoder().encode(state) {
                try? data.write(to: url)
            }
        }
    }

    private static func interactionStateURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let havenDir = appSupport.appendingPathComponent("Haven", isDirectory: true)
        try? FileManager.default.createDirectory(at: havenDir, withIntermediateDirectories: true)
        return havenDir.appendingPathComponent(interactionStateFile)
    }

    private struct InteractionState: Codable {
        let likedEventIds: Set<String>
        let zappedEventIds: [String: Int]
        let onchainZapEventIds: [String: Int]

        init(likedEventIds: Set<String>, zappedEventIds: [String: Int], onchainZapEventIds: [String: Int] = [:]) {
            self.likedEventIds = likedEventIds
            self.zappedEventIds = zappedEventIds
            self.onchainZapEventIds = onchainZapEventIds
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            likedEventIds = try container.decode(Set<String>.self, forKey: .likedEventIds)
            // Migrate from old Set<String> format if needed
            if let dict = try? container.decode([String: Int].self, forKey: .zappedEventIds) {
                zappedEventIds = dict
            } else if let set = try? container.decode(Set<String>.self, forKey: .zappedEventIds) {
                zappedEventIds = Dictionary(uniqueKeysWithValues: set.map { ($0, 0) })
            } else {
                zappedEventIds = [:]
            }
            onchainZapEventIds = try container.decodeIfPresent([String: Int].self, forKey: .onchainZapEventIds) ?? [:]
        }
    }

    // MARK: - Public API

    func refresh() {
        guard !isLoadingContacts else { return }
        newNoteCount = 0
        newSinceLastView = Date()
        
        // On iOS, pull-to-refresh also triggers a Mac relay sync to catch any missed notes
        #if os(iOS)
        MacRelaySyncService.shared.syncIfConfigured()
        #endif
        
        loadContactList { [weak self] in
            self?.subscribeToAllRelays()
        }
    }


    func switchMode(_ mode: FeedMode) {
        guard mode != feedMode else { return }
        feedMode = mode
        notes.removeAll()
        pendingNotes.removeAll()
        noteBuffer.removeAll()
        seenIds.removeAll()
        noteStats.removeAll()
        newNoteCount = 0
        newSinceLastView = Date()
        // Disconnect existing clients before re-subscribing
        feedClients.values.forEach { $0.disconnect() }
        feedClients.removeAll()
        cancellables.removeAll()

        if mode == .global {
            // Global mode doesn't need contacts — subscribe directly
            subscribeToAllRelays()
        } else {
            refresh()
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

    func applyPendingNotes() {
        guard !pendingNotes.isEmpty else { return }
        
        // Merge pending into active notes
        let newNotes = pendingNotes
        pendingNotes.removeAll()
        
        notes.append(contentsOf: newNotes)
        notes.sort { $0.createdAt > $1.createdAt }
        
        // Update new note count/tracking
        newSinceLastView = Date()
        newNoteCount = 0
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
        guard feedMode == .global || !followedPubkeys.isEmpty else { return }

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
        feedLoadingTimeout?.invalidate()
        contactLoadingTimeout?.invalidate()
        feedClients.values.forEach { $0.disconnect() }
        feedClients.removeAll()
        cancellables.removeAll()
        connectionStatus = "Disconnected"
    }

    // MARK: - Contact List (Kind 3)
    // Fetch the owner's follows from the local relay.
    // Falls back to a well-known public relay if not found locally.

    private var contactLoadingTimeout: Timer?

    private func loadContactList(completion: @escaping () -> Void) {
        let ownerNpub = ConfigService.shared.config.ownerNpub
        guard !ownerNpub.isEmpty,
              let ownerHex = Bech32.decode(ownerNpub)?.hexString else {
            completion(); return
        }

        isLoadingContacts = true
        connectionStatus = "Fetching contact list…"

        // Safety timeout: if contact loading hasn't finished in 15 seconds, force completion
        contactLoadingTimeout?.invalidate()
        contactLoadingTimeout = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, self.isLoadingContacts else { return }
                #if DEBUG
                print("FeedService: Contact loading timed out after 15s — forcing completion")
                #endif
                self.isLoadingContacts = false
                self.connectionStatus = self.followedPubkeys.isEmpty ? "Contact fetch timed out" : "Loaded \(self.followedPubkeys.count) contacts"
                completion()
            }
        }

        // Connect to all relays in parallel — use the first one that returns a non-empty contact list.
        let candidates: [URL] = ([localRelayURL] + externalRelayURLs).compactMap { $0 }
        fetchContactListInParallel(from: candidates, ownerHex: ownerHex, completion: completion)
    }

    /// Opens a connection to every candidate relay simultaneously and fires `completion`
    /// as soon as any relay returns a kind-3 event with at least one follow.
    private func fetchContactListInParallel(from relays: [URL], ownerHex: String, completion: @escaping () -> Void) {
        guard !relays.isEmpty else {
            contactLoadingTimeout?.invalidate()
            isLoadingContacts = false; completion(); return
        }

        // Shared mutable state protected by main-thread dispatch.
        var completed = false
        var eoseCount = 0
        var clients: [WebSocketClient] = []

        let finish: ([String], String, WebSocketClient) -> Void = { [weak self] pubkeys, content, winner in
            guard let self = self, !completed else { return }
            completed = true
            self.contactLoadingTimeout?.invalidate()
            // Disconnect all clients including the winner
            clients.forEach { $0.disconnect() }

            var finalPubkeys = pubkeys
            if !finalPubkeys.contains(ownerHex) { finalPubkeys.append(ownerHex) }
            self.followedPubkeys = finalPubkeys
            self.contactListContent = content
            self.isLoadingContacts = false
            self.connectionStatus = pubkeys.isEmpty ? "No contacts found" : "Loaded \(pubkeys.count) contacts"
            completion()
        }

        for url in relays {
            let c = WebSocketClient()
            c.isTemporary = true
            clients.append(c)

            c.messageSubject
                .receive(on: DispatchQueue.main)
                .sink { [weak self] msg in
                    guard !completed, let self = self else { return }
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
                        guard !pubkeys.isEmpty else { return }
                        let content = eventDict["content"] as? String ?? ""
                        finish(pubkeys, content, c)
                    } else if type == "EOSE" {
                        eoseCount += 1
                        // All relays returned EOSE with no usable contact list
                        if eoseCount >= relays.count && !completed {
                            completed = true
                            self.contactLoadingTimeout?.invalidate()
                            clients.forEach { $0.disconnect() }
                            self.isLoadingContacts = false
                            self.connectionStatus = self.followedPubkeys.isEmpty ? "No contacts found" : "Loaded \(self.followedPubkeys.count) contacts"
                            completion()
                        }
                    }
                }
                .store(in: &cancellables)

            c.$connectionState
                .receive(on: DispatchQueue.main)
                .sink { state in
                    guard !completed, state == .connected else { return }
                    let filter: [String: Any] = ["kinds": [3], "authors": [ownerHex], "limit": 1]
                    let req = ["REQ", "cl-\(UUID().uuidString.prefix(4))", filter] as [Any]
                    if let data = try? JSONSerialization.data(withJSONObject: req),
                       let str = String(data: data, encoding: .utf8) {
                        c.send(text: str)
                    }
                }
                .store(in: &cancellables)

            c.connect(url: url)
        }
    }

    // MARK: - Follow / Unfollow

    func followUser(_ pubkey: String) {
        // Don't publish if contacts haven't loaded yet — would wipe the list
        guard !isLoadingContacts, followedPubkeys.count > 1 else { return }
        guard !followedPubkeys.contains(pubkey) else { return }
        followedPubkeys.append(pubkey)
        publishContactList()
    }

    func unfollowUser(_ pubkey: String) {
        // Don't publish if contacts haven't loaded yet — would wipe the list
        guard !isLoadingContacts, followedPubkeys.count > 1 else { return }
        guard let ownerHex = Bech32.decode(ConfigService.shared.config.ownerNpub)?.hexString else { return }
        guard pubkey != ownerHex else { return }
        followedPubkeys.removeAll { $0 == pubkey }
        publishContactList()
    }

    private func publishContactList() {
        let tags = followedPubkeys.map { ["p", $0] }
        guard let event = NostrService.shared.signEvent(kind: 3, content: contactListContent, tags: tags) else { return }
        NostrService.shared.postEvent(event)
    }

    // MARK: - Feed Subscription (local + external in parallel)

    private var feedLoadingTimeout: Timer?

    private func subscribeToAllRelays() {
        guard feedMode == .global || !followedPubkeys.isEmpty else {
            connectionStatus = "Follow someone on Nostr to see their posts here"
            return
        }

        isLoadingFeed = true
        eoseCount = 0
        relayErrorCounts.removeAll()
        connectionStatus = "Loading feed…"

        // Disconnect existing feed clients
        feedClients.values.forEach { $0.disconnect() }
        feedClients.removeAll()

        // Build list: local relay first, then external
        var allURLs: [URL] = []
        if let local = localRelayURL { allURLs.append(local) }
        allURLs.append(contentsOf: externalRelayURLs)

        let totalRelays = allURLs.count

        // Safety timeout: if feed loading hasn't finished in 20 seconds, flush what we have
        feedLoadingTimeout?.invalidate()
        feedLoadingTimeout = Timer.scheduledTimer(withTimeInterval: 20.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, self.isLoadingFeed else { return }
                #if DEBUG
                print("FeedService: Feed loading timed out after 20s — flushing \(self.noteBuffer.count) buffered notes (eoseCount=\(self.eoseCount)/\(totalRelays))")
                #endif
                self.flushNoteBuffer()
                self.isLoadingFeed = false
                self.connectionStatus = self.notes.isEmpty ? "No notes found" : "Live"
            }
        }

        for url in allURLs {
            connectFeedRelay(url: url, totalRelays: totalRelays)
        }
    }

    /// Track per-relay connection failure counts for back-off
    private var relayErrorCounts: [String: Int] = [:]

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
                    self.relayErrorCounts[key] = 0
                    self.sendFeedSubscription(client: c, label: key)
                case .error:
                    let errorCount = (self.relayErrorCounts[key] ?? 0) + 1
                    self.relayErrorCounts[key] = errorCount

                    if errorCount >= 3 {
                        // After 3 failures, count this relay as done so loading can finish
                        #if DEBUG
                        print("FeedService: Relay \(key) failed \(errorCount) times — counting as EOSE")
                        #endif
                        self.eoseCount += 1
                        if self.eoseCount >= totalRelays {
                            self.feedLoadingTimeout?.invalidate()
                            self.flushNoteBuffer()
                            self.isLoadingFeed = false
                            self.connectionStatus = self.notes.isEmpty ? "No notes found" : "Live"
                        }
                    } else {
                        // Retry after delay
                        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                            guard self?.feedClients[key] === c else { return }
                            self?.connectFeedRelay(url: url, totalRelays: totalRelays)
                        }
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
        let isGlobal = feedMode == .global
        var filter: [String: Any] = [
            "kinds": [1, 6, 30023],
            "since": since,
            "limit": isGlobal ? 1000 : 500
        ]
        if !isGlobal {
            filter["authors"] = followedPubkeys
        }
        if let until = until { filter["until"] = until }
        let subId = "feed-\(label.suffix(8).filter { $0.isLetter || $0.isNumber })"

        // Filter 1: Notes (from followed authors in following mode, or anyone in global mode)
        let req = ["REQ", subId, filter] as [Any]
        if let data = try? JSONSerialization.data(withJSONObject: req),
           let str = String(data: data, encoding: .utf8) {
            client.send(text: str)
        }

        // User-specific filters only apply in following mode
        guard !isGlobal else { return }

        let ownerHex = NostrService.shared.ownerHexPubkey
        if !ownerHex.isEmpty {
            // Filter 2: Mentions (#p) of the owner (from anyone)
            var mentionsFilter = filter
            mentionsFilter["#p"] = [ownerHex]
            mentionsFilter["authors"] = nil // From anyone
            let mReq = ["REQ", "m-\(subId)", mentionsFilter] as [Any]
            if let mData = try? JSONSerialization.data(withJSONObject: mReq),
               let mStr = String(data: mData, encoding: .utf8) {
                client.send(text: mStr)
            }

            // Reactions from followed users (includes self) — used for both
            // self-like detection and per-note reaction counts.
            var reactionsFilter: [String: Any] = [
                "kinds": [7],
                "authors": followedPubkeys,
                "since": since,
                "limit": 2000
            ]
            if let until = until { reactionsFilter["until"] = until }
            let rxReq = ["REQ", "rx-\(subId)", reactionsFilter] as [Any]
            if let rxData = try? JSONSerialization.data(withJSONObject: rxReq),
               let rxStr = String(data: rxData, encoding: .utf8) {
                client.send(text: rxStr)
            }

            // Incoming zap receipts: Kind 9735 where #p = owner (zaps received on my notes)
            var incomingZapsFilter: [String: Any] = [
                "kinds": [9735],
                "#p": [ownerHex],
                "since": since,
                "limit": 500
            ]
            if let until = until { incomingZapsFilter["until"] = until }
            let inZapsReq = ["REQ", "zaps-in-\(subId)", incomingZapsFilter] as [Any]
            if let data = try? JSONSerialization.data(withJSONObject: inZapsReq),
               let str = String(data: data, encoding: .utf8) {
                client.send(text: str)
            }

            // Outgoing zap requests: Kind 9734 authored by owner (zaps I sent)
            var outgoingZapsFilter: [String: Any] = [
                "kinds": [9734],
                "authors": [ownerHex],
                "since": since,
                "limit": 500
            ]
            if let until = until { outgoingZapsFilter["until"] = until }
            let outZapsReq = ["REQ", "zaps-out-\(subId)", outgoingZapsFilter] as [Any]
            if let data = try? JSONSerialization.data(withJSONObject: outZapsReq),
               let str = String(data: data, encoding: .utf8) {
                client.send(text: str)
            }
        }
    }

    /// Called on processingQueue — parses JSON off the main thread, accumulates in background buffers.
    /// A periodic flush delivers batched results to the main thread.
    private nonisolated func handleFeedMsgBackground(_ msg: String, totalRelays: Int) {
        guard let data = msg.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let type = json[0] as? String else { return }

        if type == "EOSE" {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.eoseCount += 1
                if self.eoseCount >= totalRelays {
                    self.feedLoadingTimeout?.invalidate()
                    self.drainBackgroundBuffers()
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

        // Ignore events with future timestamps (> 60 seconds in the future) to prevent feed corruption
        if Double(createdAt) > Date().timeIntervalSince1970 + 60 {
            return
        }

        // Handle Reactions (Kind 7) — track for self-like detection + per-note counting
        if kind == 7 {
            if let targetId = tags.first(where: { $0.count >= 2 && $0[0] == "e" })?[1] {
                let acc = self.bgAccumulator
                let reactorPubkey = pubkey
                let eventId = id
                processingQueue.async { [weak self] in
                    // Deduplicate reactions from multiple relays
                    guard !acc.seenEngagementIds.contains(eventId) else { return }
                    acc.seenEngagementIds.insert(eventId)
                    acc.reactionEvents.append((targetId: targetId, pubkey: reactorPubkey))
                    self?.scheduleBackgroundFlush()
                }
            }
            return
        }

        // Handle Zap Receipts (Kind 9735) and Zap Requests (Kind 9734)
        // Forward to NostrService so ViewerView can access them via nostrService.events
        if kind == 9735 || kind == 9734 {
            if let evData = try? JSONSerialization.data(withJSONObject: ev),
               let event = try? JSONDecoder().decode(NostrEvent.self, from: evData) {
                DispatchQueue.main.async {
                    NostrService.shared.injectEvent(event)
                }
            }
            return
        }

        var parsedContent = content
        var originalPubkey: String? = nil
        var repostNeedsFetch: String? = nil

        if kind == 6 {
            if let data = content.data(using: .utf8),
               let inner = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let innerContent = inner["content"] as? String {
                parsedContent = innerContent
                originalPubkey = inner["pubkey"] as? String
            } else {
                // Empty-content repost — extract the referenced event ID from e-tags
                parsedContent = ""
                if let refId = tags.first(where: { $0.count >= 2 && $0[0] == "e" })?[1] {
                    repostNeedsFetch = refId
                }
            }
        }

        // Build FeedNote on background thread (including regex caching in init)
        let note = FeedNote(
            id: id,
            pubkey: originalPubkey ?? pubkey,
            content: parsedContent,
            createdAt: Date(timeIntervalSince1970: TimeInterval(createdAt)),
            tags: tags,
            kind: kind,
            repostedBy: kind == 6 ? pubkey : nil
        )

        // Filter out obvious spam/noise from being processed
        if FeedNote.isNoiseOrSpam(content: note.content, tags: note.tags) {
            return
        }

        // Accumulate on processing queue — NO per-event main thread dispatch
        let acc = self.bgAccumulator
        let fetchId = repostNeedsFetch
        processingQueue.async { [weak self] in
            acc.notes.append(note)
            acc.profiles.append(pubkey)
            if let op = originalPubkey { acc.profiles.append(op) }

            // Track engagement: replies (kind 1 with parent) and reposts (kind 6)
            if kind == 1 {
                let eTags = tags.filter { $0.count >= 2 && $0[0] == "e" }
                let nonMentionETags = eTags.filter { tag in
                    guard tag.count >= 4 else { return true }
                    return tag[3] != "mention"
                }
                if let parentId = nonMentionETags.last?[1] {
                    acc.replyTargets.append(parentId)
                }
            } else if kind == 6 {
                if let targetId = tags.first(where: { $0.count >= 2 && $0[0] == "e" })?[1] {
                    acc.repostTargets.append(targetId)
                }
            }

            // Trigger fetch of the original note for empty-content reposts
            if let refId = fetchId {
                DispatchQueue.main.async {
                    self?.fetchMissingNote(id: refId)
                }
            }
            self?.scheduleBackgroundFlush()
        }
    }

    /// Schedule a single coalesced flush of the background buffers → main thread.
    /// Must be called on processingQueue.
    private nonisolated func scheduleBackgroundFlush() {
        dispatchPrecondition(condition: .onQueue(processingQueue))
        let acc = bgAccumulator
        guard !acc.flushScheduled else { return }
        acc.flushScheduled = true
        processingQueue.asyncAfter(deadline: .now() + BackgroundAccumulator.flushInterval) { [weak self] in
            self?.deliverBackgroundBatch()
        }
    }

    /// Take everything accumulated on the processing queue and deliver it to main in one dispatch.
    private nonisolated func deliverBackgroundBatch() {
        dispatchPrecondition(condition: .onQueue(processingQueue))
        let snap = bgAccumulator.drain()

        guard !snap.notes.isEmpty || !snap.reactionEvents.isEmpty || !snap.replyTargets.isEmpty || !snap.repostTargets.isEmpty else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.applySnapshot(snap)
        }
    }

    /// Force-drain background buffers synchronously (called on main before EOSE flush).
    private func drainBackgroundBuffers() {
        let acc = bgAccumulator
        var snap: BackgroundAccumulator.Snapshot!
        processingQueue.sync {
            snap = acc.drain()
        }
        applySnapshot(snap)
    }

    /// Apply a drained snapshot to main-actor state.
    private func applySnapshot(_ snap: BackgroundAccumulator.Snapshot) {
        var added = false
        for note in snap.notes {
            guard !seenIds.contains(note.id) else { continue }
            seenIds.insert(note.id)
            noteBuffer.append(note)
            added = true
        }

        let uniquePubkeys = Set(snap.profiles).subtracting(Set(NostrService.shared.profiles.keys))
        if !uniquePubkeys.isEmpty {
            NostrService.shared.fetchMissingProfiles(for: Array(uniquePubkeys))
        }

        // Process reaction events: self-like detection + per-note counting
        let hasEngagement = !snap.reactionEvents.isEmpty || !snap.replyTargets.isEmpty || !snap.repostTargets.isEmpty
        if hasEngagement {
            let ownerHex = NostrService.shared.ownerHexPubkey

            // Self-likes: reactions authored by the owner
            if !ownerHex.isEmpty && !snap.reactionEvents.isEmpty {
                let selfLikes = snap.reactionEvents.compactMap { $0.pubkey == ownerHex ? $0.targetId : nil }
                if !selfLikes.isEmpty {
                    let before = likedEventIds.count
                    likedEventIds.formUnion(selfLikes)
                    if likedEventIds.count > before {
                        saveInteractionState()
                    }
                }
            }

            // Merge engagement counts (single dictionary assignment for one @Published update)
            var updated = noteStats
            for (targetId, _) in snap.reactionEvents {
                var s = updated[targetId] ?? NoteStats()
                s.reactions += 1
                updated[targetId] = s
            }
            for parentId in snap.replyTargets {
                var s = updated[parentId] ?? NoteStats()
                s.replies += 1
                updated[parentId] = s
            }
            for targetId in snap.repostTargets {
                var s = updated[targetId] ?? NoteStats()
                s.reposts += 1
                updated[targetId] = s
            }
            noteStats = updated
        }

        if added {
            scheduleNoteFlush()
        }
    }

    // MARK: - Batched Note Flushing

    /// Maximum notes kept in memory. Older notes are dropped on flush.
    private static let maxNotes = 800

    private func scheduleNoteFlush() {
        guard noteFlushTimer == nil else { return }
        noteFlushTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
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
        noteBuffer.removeAll(keepingCapacity: true)

        // Prefetch media content types for the batch — moves HTTP HEAD detection
        // out of the rendering path so FeedMediaView has cached types when it renders
        let allMediaURLs = batch.flatMap { $0.mediaURLs }
        if !allMediaURLs.isEmpty {
            MediaTypeDetector.shared.prefetchContentTypes(for: allMediaURLs)
        }

        // During initial load, add everything at once then sort once
        if notes.isEmpty || isLoadingFeed {
            notes.append(contentsOf: batch)
            notes.sort { $0.createdAt > $1.createdAt }
            // Cap to prevent memory bloat
            if notes.count > Self.maxNotes {
                notes.removeLast(notes.count - Self.maxNotes)
            }
            return
        }

        // Live updates: buffer new top-level notes to prevent feed jumping
        let newestDate = notes.first?.createdAt ?? Date.distantPast
        let autoLoad = ConfigService.shared.config.autoLoadNewPosts
        let driftThreshold = newestDate.addingTimeInterval(-60) // 60 seconds grace period for relay clock drift

        var toAdd: [FeedNote] = []
        var toPending: [FeedNote] = []

        for note in batch {
            if note.createdAt > driftThreshold && !note.isReply && !autoLoad {
                toPending.append(note)
            } else {
                toAdd.append(note)
            }
        }

        if !toAdd.isEmpty {
            notes.append(contentsOf: toAdd)
            notes.sort { $0.createdAt > $1.createdAt }
            if notes.count > Self.maxNotes {
                notes.removeLast(notes.count - Self.maxNotes)
            }
        }

        if !toPending.isEmpty {
            let updatedPending = pendingNotes + toPending
            let uniqueMap = Dictionary(updatedPending.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            pendingNotes = uniqueMap.values.sorted { $0.createdAt > $1.createdAt }
        }
    }

    // MARK: - Note Fetching logic

    private func scheduleNoteFetchFlush() {
        guard noteFetchTimer == nil else { return }
        noteFetchTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
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

            // Use a fast-path handler that bypasses the batch pipeline so parent
            // notes appear in the thread preview as soon as the relay responds.
            c.messageSubject
                .receive(on: DispatchQueue.main)
                .sink { [weak self] msg in self?.handleParentNoteFetch(msg) }
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
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                            c.disconnect()
                        }
                    }
                }
                .store(in: &cancellables)

            c.connect(url: url)
        }
    }

    /// Fast-path handler for parent note fetches — inserts directly into notes on the main
    /// thread without going through the batch accumulator or flush timers.
    private func handleParentNoteFetch(_ msg: String) {
        guard let data = msg.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let type = json[0] as? String,
              type == "EVENT", json.count >= 3,
              let ev = json[2] as? [String: Any],
              let id        = ev["id"]        as? String,
              let pubkey    = ev["pubkey"]     as? String,
              let content   = ev["content"]    as? String,
              let createdAt = ev["created_at"] as? Int64,
              let kind      = ev["kind"]       as? Int,
              let tags      = ev["tags"]       as? [[String]]
        else { return }

        guard !seenIds.contains(id) else { return }

        let note = FeedNote(
            id: id,
            pubkey: pubkey,
            content: content,
            createdAt: Date(timeIntervalSince1970: TimeInterval(createdAt)),
            tags: tags,
            kind: kind
        )

        guard !FeedNote.isNoiseOrSpam(content: note.content, tags: note.tags) else { return }

        seenIds.insert(id)
        notes.append(note)
        NostrService.shared.fetchMissingProfiles(for: [pubkey])
    }
}
