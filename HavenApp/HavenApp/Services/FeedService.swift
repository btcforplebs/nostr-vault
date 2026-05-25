import Foundation
import Combine
import SwiftUI

// MARK: - Models

/// Lightweight engagement counts per note, populated from relay data.
struct NoteStats {
    var replies: Int = 0
    var reactions: Int = 0
    var reposts: Int = 0
    var zaps: Int = 0
}

struct FeedNote: Identifiable, Hashable, Equatable {
    let id: String
    let pubkey: String
    let content: String
    let createdAt: Date
    let tags: [[String]]
    let kind: Int
    let repostedBy: String?

    static func == (lhs: FeedNote, rhs: FeedNote) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    // Cached at init to avoid recomputing on every SwiftUI render
    let isReply: Bool
    let replyToPubkey: String?
    let parentEventId: String?
    let mediaURLs: [URL]
    let quotedEventIds: [String]

    /// The event ID of the original note referenced by a kind 6 repost (from e-tags).
    let repostedEventId: String?

    init(id: String, pubkey: String, content: String, createdAt: Date, tags: [[String]], kind: Int, repostedBy: String? = nil) {
        // NIP-18: a kind 6 repost SHOULD embed the full original event as stringified JSON
        // in `content`. When present, swap to the inner author/content/tags so the UI renders
        // the reposted note directly. The outer pubkey becomes `repostedBy`.
        // Always compute `repostedEventId` from the OUTER e-tag before any swap.
        let outerETags = tags.filter { $0.count >= 2 && $0[0] == "e" }
        let outerRepostedEventId = kind == 6 ? outerETags.first?[1] : nil

        var resolvedPubkey = pubkey
        var resolvedContent = content
        var resolvedTags = tags
        var resolvedRepostedBy = repostedBy

        if kind == 6,
           let data = content.data(using: .utf8),
           let inner = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let innerContent = inner["content"] as? String,
           let innerPubkey = inner["pubkey"] as? String {
            resolvedPubkey = innerPubkey
            resolvedContent = innerContent
            if let innerTags = inner["tags"] as? [[String]] {
                resolvedTags = innerTags
            }
            if resolvedRepostedBy == nil { resolvedRepostedBy = pubkey }
        }

        self.id = id
        self.pubkey = resolvedPubkey
        self.content = resolvedContent
        self.createdAt = createdAt
        self.tags = resolvedTags
        self.kind = kind
        self.repostedBy = resolvedRepostedBy

        // Cache tag-derived properties (use resolved tags so inner imeta/reply data wins)
        let eTags = resolvedTags.filter { $0.count >= 2 && $0[0] == "e" }
        let nonMentionETags = eTags.filter { tag in
            guard tag.count >= 4 else { return true }
            return tag[3] != "mention"
        }
        // Kind 6 reposts have e-tags but are not replies
        self.isReply = kind != 6 && !nonMentionETags.isEmpty
        self.replyToPubkey = kind != 6 ? resolvedTags.first { $0.count >= 2 && $0[0] == "p" }?[1] : nil
        self.parentEventId = kind != 6 ? resolvedTags.last { $0.count >= 2 && $0[0] == "e" }?[1] : nil

        self.repostedEventId = outerRepostedEventId

        // Cache regex-derived properties (expensive — only compute once)
        let contentURLs = Self.parseMediaURLs(from: resolvedContent)
        // NIP-92 imeta tags carry URLs for uploads without file extensions
        let imetaURLs: [URL] = resolvedTags.compactMap { tag in
            guard tag.first == "imeta", tag.count >= 2 else { return nil }
            for field in tag.dropFirst() {
                if field.hasPrefix("url ") {
                    let urlStr = String(field.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                    return URL(string: urlStr)
                }
            }
            return nil
        }
        var seen = Set<String>()
        self.mediaURLs = (contentURLs + imetaURLs).filter { seen.insert($0.absoluteString).inserted }
        self.quotedEventIds = Self.parseQuotedEventIds(from: resolvedContent)
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
        try? NSRegularExpression(pattern: #"https?://\S+?\.(?:jpg|jpeg|png|gif|webp|mp4|mov|webm|heic|hevc|h265)(?:\?\S+)?"#, options: .caseInsensitive)
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
    /// Raw event JSON strings for NIP-18 repost embedding (id → stringified JSON with sig).
    var rawEventEntries: [(id: String, json: String)] = []
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
        let rawEventEntries: [(id: String, json: String)]
    }

    func drain() -> Snapshot {
        let snap = Snapshot(
            notes: notes,
            profiles: profiles,
            reactionEvents: reactionEvents,
            replyTargets: replyTargets,
            repostTargets: repostTargets,
            rawEventEntries: rawEventEntries
        )
        notes.removeAll(keepingCapacity: true)
        profiles.removeAll(keepingCapacity: true)
        reactionEvents.removeAll(keepingCapacity: true)
        replyTargets.removeAll(keepingCapacity: true)
        repostTargets.removeAll(keepingCapacity: true)
        rawEventEntries.removeAll(keepingCapacity: true)
        flushScheduled = false

        // Cap dedup set to prevent unbounded growth
        if seenEngagementIds.count > Self.maxEngagementIds {
            seenEngagementIds.removeAll(keepingCapacity: true)
        }
        return snap
    }
}

// MARK: - FeedService

enum MediaFeedMode: String, CaseIterable {
    case following = "Following"
    case global = "Global"
}

/// Feed mode: following (contacts only), discovery (extended network), global (all notes), or media grid.
enum FeedMode: String, CaseIterable {
    case following = "Following"
    case discovery = "Discovery"
    case global = "Global"
    case media = "Media"
}

/// Per-account, in-memory snapshot of the feed state. Captured before switching
/// accounts and restored on switch-back so the feed reappears instantly instead
/// of going through a full cold reload. Engagement state (likes/zaps) is also
/// scoped here so it doesn't leak across accounts.
struct AccountFeedSnapshot {
    var notes: [FeedNote] = []
    var parentNotesCache: [String: FeedNote] = [:]
    var followedPubkeys: [String] = []
    var extendedNetworkPubkeys: [String] = []
    var seenIds: Set<String> = []
    var noteStats: [String: NoteStats] = [:]
    var likedEventIds: Set<String> = []
    var zappedEventIds: [String: Int] = [:]
    var onchainZapEventIds: [String: Int] = [:]
    var contactListContent: String = ""
    var hasAttemptedContactLoad: Bool = false
    var capturedAt: Date = Date()
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
    @Published var mediaFeedMode: MediaFeedMode = .following
    @Published var notes: [FeedNote] = []
    @Published var parentNotesCache: [String: FeedNote] = [:]
    @Published var followedPubkeys: [String] = []
    @Published var extendedNetworkPubkeys: [String] = []
    @Published var isLoadingContacts = false
    /// True once contact loading has completed at least once (success, empty, or timeout).
    /// Used to gate follow/unfollow so we don't publish before the kind-3 has had a chance to arrive.
    private var hasAttemptedContactLoad = false
    @Published var isLoadingExtendedNetwork = false
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
    @Published var repostedEventIds: Set<String> = []
    @Published var zappedEventIds: [String: Int] = [:]
    @Published var onchainZapEventIds: [String: Int] = [:]
    /// Per-note engagement counts (replies, reactions, reposts) from relay data.
    @Published var noteStats: [String: NoteStats] = [:]

    /// Cache of raw event JSON strings for NIP-18 repost embedding.
    /// Key: event ID, Value: complete stringified JSON of the event (includes sig).
    private(set) var rawEventCache: [String: String] = [:]
    private static let maxRawEventCacheSize = 1000

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

    /// Used for de-duping relay URLs across the floor + outbox set.
    private static func normalizeRelayKey(_ urlStr: String) -> String? {
        guard let url = URL(string: urlStr), let host = url.host else { return urlStr.lowercased() }
        var key = "\(url.scheme ?? "wss")://\(host.lowercased())"
        if let port = url.port { key += ":\(port)" }
        let path = url.path.hasSuffix("/") ? String(url.path.dropLast()) : url.path
        if !path.isEmpty { key += path }
        return key
    }

/// In-memory per-account feed snapshots keyed by `activeAccountNpub`
    /// (empty string for the default/owner account). Captured before each
    /// account switch and restored when switching back, so re-switching is
    /// instant and the relay top-up runs as a background refresh.
    private var accountSnapshots: [String: AccountFeedSnapshot] = [:]
    /// The npub the currently-loaded feed belongs to. Used to know which key
    /// to snapshot against when the active account changes.
    private var loadedSnapshotNpub: String = ""
    /// True while a background top-up is running against an already-rendered
    /// snapshot. Used by the UI to show a small inline "Syncing…" pill instead
    /// of the full-screen loading spinner.
    @Published var isSyncing: Bool = false

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

    private var configCancellables = Set<AnyCancellable>()

    private init() {
        // FeedService no longer manages profiles; NostrService does.
        loadedSnapshotNpub = currentSnapshotKey()
        loadInteractionState(forKey: loadedSnapshotNpub)

        // Listen to active account changes to reload the feed automatically.
        // We snapshot the previous account's state into memory and either
        // restore an existing snapshot (instant) or run a cold load.
        ConfigService.shared.$config
            .map { $0.activeAccountNpub }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.handleAccountSwitch()
            }
            .store(in: &configCancellables)
    }

    /// Stable in-memory cache key for the active account. Uses the configured
    /// `activeAccountNpub`, falling back to "owner" when the owner account is
    /// active so we never key on an empty string.
    private func currentSnapshotKey() -> String {
        let npub = ConfigService.shared.config.activeAccountNpub.trimmingCharacters(in: .whitespacesAndNewlines)
        return npub.isEmpty ? "owner" : npub
    }

    /// Capture the current published feed state into `accountSnapshots[key]`.
    /// Bounded to ~200 notes so re-switching is cheap; full backfill comes
    /// from the top-up subscription that runs immediately after.
    private func captureSnapshot(forKey key: String) {
        guard !key.isEmpty else { return }
        let cappedNotes = Array(notes.prefix(200))
        let snap = AccountFeedSnapshot(
            notes: cappedNotes,
            parentNotesCache: parentNotesCache,
            followedPubkeys: followedPubkeys,
            extendedNetworkPubkeys: extendedNetworkPubkeys,
            seenIds: seenIds,
            noteStats: noteStats,
            likedEventIds: likedEventIds,
            zappedEventIds: zappedEventIds,
            onchainZapEventIds: onchainZapEventIds,
            contactListContent: contactListContent,
            hasAttemptedContactLoad: hasAttemptedContactLoad,
            capturedAt: Date()
        )
        accountSnapshots[key] = snap
    }

    /// Restore a previously captured snapshot into published state. Returns
    /// true if a snapshot existed and was restored.
    @discardableResult
    private func restoreSnapshot(forKey key: String) -> Bool {
        guard let snap = accountSnapshots[key] else { return false }
        notes = snap.notes
        parentNotesCache = snap.parentNotesCache
        followedPubkeys = snap.followedPubkeys
        extendedNetworkPubkeys = snap.extendedNetworkPubkeys
        seenIds = snap.seenIds
        noteStats = snap.noteStats
        likedEventIds = snap.likedEventIds
        zappedEventIds = snap.zappedEventIds
        onchainZapEventIds = snap.onchainZapEventIds
        contactListContent = snap.contactListContent
        hasAttemptedContactLoad = snap.hasAttemptedContactLoad
        pendingNotes.removeAll()
        noteBuffer.removeAll()
        return true
    }

    /// Reset just the in-memory published feed state (does not touch snapshots).
    /// Used before a cold load when no snapshot exists for the new account.
    private func clearInMemoryFeedState() {
        followedPubkeys.removeAll()
        extendedNetworkPubkeys.removeAll()
        notes.removeAll()
        parentNotesCache.removeAll()
        pendingNotes.removeAll()
        noteBuffer.removeAll()
        seenIds.removeAll()
        fetchingNoteIds.removeAll()
        noteFetchQueue.removeAll()
        noteFetchTimer?.invalidate()
        noteFetchTimer = nil
        noteStats.removeAll()
        likedEventIds.removeAll()
        zappedEventIds.removeAll()
        onchainZapEventIds.removeAll()
        contactListContent = ""
        hasAttemptedContactLoad = false
    }

    /// Snapshot the old account, restore (or cold-load) the new account, then
    /// kick off a relay top-up against the now-current state.
    private func handleAccountSwitch() {
        let previousKey = loadedSnapshotNpub
        let newKey = currentSnapshotKey()
        guard previousKey != newKey else { return }

        // 1. Stash the just-rendered state under the previous npub.
        captureSnapshot(forKey: previousKey)

        // 2. Tear down only the feed-level WebSocket connections — global
        // services (profile + Kind 10002 fetches) keep their clients.
        disconnectFeedClients()

        // 3. Cancel in-flight loading flags + timers so the new flow isn't blocked.
        isLoadingContacts = false
        isLoadingExtendedNetwork = false
        isLoadingFeed = false
        isSyncing = false
        contactLoadingTimeout?.invalidate()
        feedLoadingTimeout?.invalidate()
        extendedNetworkTimeout?.invalidate()
        cancellables.removeAll()

        // 4. Either restore an in-memory snapshot OR cold-load.
        loadedSnapshotNpub = newKey
        let restored = restoreSnapshot(forKey: newKey)
        if !restored {
            // No cached feed — load persisted interaction state for this
            // account from disk so likes/zaps appear correctly even on first
            // visit after launch.
            clearInMemoryFeedState()
            loadInteractionState(forKey: newKey)
        }
        newNoteCount = 0
        newSinceLastView = Date()

        // 5. Kick off relay traffic.
        if restored {
            // Background top-up: subscribe to relays but keep the cached feed
            // visible. The inline syncing pill replaces the full-screen spinner.
            topUpFromRelays()
        } else if feedMode == .global || (feedMode == .media && mediaFeedMode == .global) {
            subscribeToAllRelays()
        } else {
            refresh()
        }
    }

    // MARK: - Interaction State Persistence (per-account)

    /// Legacy single-file path used before per-account state was introduced.
    /// Migrated to the owner account on first load.
    private static let legacyInteractionStateFile = "interaction_state.json"

    private var interactionSaveThrottle: Date = .distantPast

    /// Load engagement state (likes / zaps) for the given account snapshot key
    /// into the published properties. Falls back to the legacy global file when
    /// no per-account file exists yet.
    private func loadInteractionState(forKey key: String) {
        let url = Self.interactionStateURL(forKey: key)
        if let data = try? Data(contentsOf: url),
           let state = try? JSONDecoder().decode(InteractionState.self, from: data) {
            self.likedEventIds = state.likedEventIds
            self.zappedEventIds = state.zappedEventIds
            self.onchainZapEventIds = state.onchainZapEventIds
            #if DEBUG
            print("FeedService: Loaded \(state.likedEventIds.count) likes, \(state.zappedEventIds.count) zaps for account \(key.prefix(8))")
            #endif
            return
        }

        // Migration: read the old shared file once and assign it to whichever
        // account first asks for it (typically the owner on launch).
        let legacy = Self.interactionStateURL(legacy: true)
        if let data = try? Data(contentsOf: legacy),
           let state = try? JSONDecoder().decode(InteractionState.self, from: data) {
            self.likedEventIds = state.likedEventIds
            self.zappedEventIds = state.zappedEventIds
            self.onchainZapEventIds = state.onchainZapEventIds
            #if DEBUG
            print("FeedService: Migrated legacy interaction state for account \(key.prefix(8))")
            #endif
            // Persist under the new per-account file so the legacy file can be
            // dropped on next launch.
            interactionSaveThrottle = .distantPast
            saveInteractionState()
            return
        }

        self.likedEventIds = []
        self.zappedEventIds = [:]
        self.onchainZapEventIds = [:]
    }

    func saveInteractionState() {
        // Throttle saves to at most once per 2 seconds
        let now = Date()
        guard now.timeIntervalSince(interactionSaveThrottle) > 2.0 else { return }
        interactionSaveThrottle = now

        let state = InteractionState(likedEventIds: likedEventIds, zappedEventIds: zappedEventIds, onchainZapEventIds: onchainZapEventIds)
        let url = Self.interactionStateURL(forKey: loadedSnapshotNpub)
        DispatchQueue.global(qos: .utility).async {
            if let data = try? JSONEncoder().encode(state) {
                try? data.write(to: url)
            }
        }
    }

    private static func interactionStateURL(forKey key: String) -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let havenDir = appSupport.appendingPathComponent("Haven", isDirectory: true)
        try? FileManager.default.createDirectory(at: havenDir, withIntermediateDirectories: true)
        let safeKey = key.isEmpty ? "owner" : key.replacingOccurrences(of: "/", with: "_")
        return havenDir.appendingPathComponent("interaction_state_\(safeKey).json")
    }

    private static func interactionStateURL(legacy: Bool) -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let havenDir = appSupport.appendingPathComponent("Haven", isDirectory: true)
        try? FileManager.default.createDirectory(at: havenDir, withIntermediateDirectories: true)
        return havenDir.appendingPathComponent(legacyInteractionStateFile)
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
            guard let self = self else { return }
            if self.feedMode == .discovery {
                self.loadExtendedNetwork { [weak self] in
                    self?.subscribeToAllRelays()
                }
            } else {
                self.subscribeToAllRelays()
            }
        }
    }


    func switchMode(_ mode: FeedMode) {
        guard mode != feedMode else { return }
        feedMode = mode
        notes.removeAll()
        parentNotesCache.removeAll()
        pendingNotes.removeAll()
        noteBuffer.removeAll()
        seenIds.removeAll()
        fetchingNoteIds.removeAll()
        noteFetchQueue.removeAll()
        noteFetchTimer?.invalidate()
        noteFetchTimer = nil
        noteStats.removeAll()
        newNoteCount = 0
        newSinceLastView = Date()
        isSyncing = false
        // Disconnect feed clients before re-subscribing.
        disconnectFeedClients()
        cancellables.removeAll()

        if mode == .global || (mode == .media && mediaFeedMode == .global) {
            // Global mode doesn't need contacts — subscribe directly
            subscribeToAllRelays()
        } else {
            refresh()
        }
    }

    /// Discard the cached snapshot for the current account and run a full
    /// cold reload. Use sparingly — the normal account-switch path already
    /// restores instantly from the in-memory snapshot.
    func forceReload() {
        accountSnapshots.removeValue(forKey: loadedSnapshotNpub)
        clearInMemoryFeedState()
        newNoteCount = 0
        newSinceLastView = Date()
        isLoadingContacts = false
        isLoadingFeed = false
        isLoadingExtendedNetwork = false
        isSyncing = false
        contactLoadingTimeout?.invalidate()
        feedLoadingTimeout?.invalidate()
        extendedNetworkTimeout?.invalidate()
        disconnectFeedClients()
        cancellables.removeAll()

        if feedMode == .global || (feedMode == .media && mediaFeedMode == .global) {
            subscribeToAllRelays()
        } else {
            refresh()
        }
    }

    /// Close only the feed-level WebSocket connections. The
    /// `NostrService.clients` pool is left alone so profile and Kind-10002
    /// lookups carry over across account switches.
    private func disconnectFeedClients() {
        feedClients.values.forEach { $0.disconnect() }
        feedClients.removeAll()
    }

    /// Background refresh against an already-rendered snapshot. Re-subscribes
    /// to relays so newer notes stream in on top of the cached feed, and
    /// kicks off a contact-list re-fetch in parallel so a stale follow set
    /// gets updated without blocking the visible feed.
    private func topUpFromRelays() {
        let isGlobalLike = feedMode == .global || (feedMode == .media && mediaFeedMode == .global)
        guard !followedPubkeys.isEmpty || isGlobalLike else {
            // Snapshot had no follows — fall back to the cold-start flow.
            refresh()
            return
        }

        isSyncing = true
        newSinceLastView = Date()

        // 1. Subscribe to relays immediately using the cached follow set.
        if isGlobalLike || !followedPubkeys.isEmpty {
            subscribeToAllRelays()
        }

        // 2. Re-fetch the contact list in the background. When it lands,
        // newly-followed authors are picked up by the running subscription on
        // the next refresh cycle (and `publishContactList` writes the diff).
        // We don't block on it.
        loadContactList { [weak self] in
            guard let self = self else { return }
            self.isSyncing = false
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

    func removeNote(id: String) {
        notes.removeAll { $0.id == id }
        pendingNotes.removeAll { $0.id == id }
        parentNotesCache.removeValue(forKey: id)
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
        guard findNote(id: id) == nil, !fetchingNoteIds.contains(id) else { return }
        fetchingNoteIds.insert(id)
        noteFetchQueue.insert(id)
        scheduleNoteFetchFlush()
    }

    /// Looks up a note in the local parent notes cache or in the main feed list.
    func findNote(id: String) -> FeedNote? {
        if let cached = parentNotesCache[id] {
            return cached
        }
        return notes.first(where: { $0.id == id })
    }

    /// Load older notes (pagination) — fetches the page before the oldest note currently shown.
    func loadMore() {
        guard !isLoadingFeed, let oldest = notes.last?.createdAt else { return }
        let until = Int64(oldest.timeIntervalSince1970) - 1
        if (feedMode == .following || (feedMode == .media && mediaFeedMode == .following)) && followedPubkeys.isEmpty { return }
        if feedMode == .discovery && extendedNetworkPubkeys.isEmpty { return }

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
        disconnectFeedClients()
        cancellables.removeAll()
        connectionStatus = "Disconnected"
        isSyncing = false
    }

    // MARK: - Contact List (Kind 3)
    // Fetch the owner's follows from the local relay.
    // Falls back to a well-known public relay if not found locally.

    private var contactLoadingTimeout: Timer?

    private func loadContactList(completion: @escaping () -> Void) {
        let activeNpub = ConfigService.shared.config.activeAccountNpub.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetNpub = activeNpub.isEmpty ? ConfigService.shared.config.ownerNpub : activeNpub
        guard !targetNpub.isEmpty,
              let ownerHex = Bech32.decode(targetNpub)?.hexString else {
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
                self.hasAttemptedContactLoad = true
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
            isLoadingContacts = false
            hasAttemptedContactLoad = true
            completion(); return
        }

        // Shared mutable state protected by main-thread dispatch.
        var completed = false
        var eoseCount = 0
        var clients: [WebSocketClient] = []

        let finish: ([String], String, WebSocketClient) -> Void = { [weak self] pubkeys, content, winner in
            guard let self = self, !completed else { return }
            // Discard responses that raced past an account switch.
            guard ownerHex == ConfigService.shared.activeAccountHexPubkey else {
                clients.forEach { $0.disconnect() }
                return
            }
            completed = true
            self.contactLoadingTimeout?.invalidate()
            // Disconnect all clients including the winner
            clients.forEach { $0.disconnect() }

            var finalPubkeys = pubkeys
            if !finalPubkeys.contains(ownerHex) { finalPubkeys.append(ownerHex) }

            // Auto-follow whitelisted accounts so they appear in the default feed
            for npub in ConfigService.shared.config.whitelistedNpubs {
                if let hex = Bech32.decode(npub)?.hexString, !finalPubkeys.contains(hex) {
                    finalPubkeys.append(hex)
                }
            }

            self.followedPubkeys = finalPubkeys
            self.contactListContent = content
            self.isLoadingContacts = false
            self.hasAttemptedContactLoad = true
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
                            guard ownerHex == ConfigService.shared.activeAccountHexPubkey else {
                                completed = true
                                clients.forEach { $0.disconnect() }
                                return
                            }
                            completed = true
                            self.contactLoadingTimeout?.invalidate()
                            clients.forEach { $0.disconnect() }
                            self.isLoadingContacts = false
                            self.hasAttemptedContactLoad = true
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

    // MARK: - Extended Network (Discovery Feed)
    
    private var extendedNetworkTimeout: Timer?
    
    private func loadExtendedNetwork(completion: @escaping () -> Void) {
        guard !followedPubkeys.isEmpty else {
            completion()
            return
        }
        
        isLoadingExtendedNetwork = true
        connectionStatus = "Analyzing network..."
        
        extendedNetworkTimeout?.invalidate()
        extendedNetworkTimeout = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, self.isLoadingExtendedNetwork else { return }
                self.isLoadingExtendedNetwork = false
                completion()
            }
        }
        
        let candidates: [URL] = ([localRelayURL] + externalRelayURLs).compactMap { $0 }
        fetchExtendedNetworkInParallel(from: candidates, completion: completion)
    }

    private func fetchExtendedNetworkInParallel(from relays: [URL], completion: @escaping () -> Void) {
        guard !relays.isEmpty else {
            extendedNetworkTimeout?.invalidate()
            isLoadingExtendedNetwork = false
            completion()
            return
        }

        var completed = false
        var eoseCount = 0
        var clients: [WebSocketClient] = []
        var mutualCounts: [String: Int] = [:]
        
        // Exclude current follows and owner
        let excludeSet = Set(followedPubkeys)

        let finish: () -> Void = { [weak self] in
            guard let self = self, !completed else { return }
            completed = true
            self.extendedNetworkTimeout?.invalidate()
            clients.forEach { $0.disconnect() }
            
            // Sort by mutual count
            let sorted = mutualCounts.sorted { $0.value > $1.value }
            // Take top 500
            self.extendedNetworkPubkeys = Array(sorted.prefix(500).map { $0.key })
            
            self.isLoadingExtendedNetwork = false
            completion()
        }

        for url in relays {
            let c = WebSocketClient()
            c.isTemporary = true
            clients.append(c)

            c.messageSubject
                .receive(on: DispatchQueue.global(qos: .userInitiated))
                .sink { msg in
                    guard !completed else { return }
                    guard let data = msg.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
                          let type = json[0] as? String else { return }

                    if type == "EVENT", json.count >= 3,
                       let eventDict = json[2] as? [String: Any],
                       let kind = eventDict["kind"] as? Int, kind == 3,
                       let tags = eventDict["tags"] as? [[String]] {
                        
                        var localCounts: [String: Int] = [:]
                        for t in tags {
                            if t.count >= 2, t[0] == "p" {
                                let pk = t[1]
                                if !excludeSet.contains(pk) {
                                    localCounts[pk, default: 0] += 1
                                }
                            }
                        }
                        
                        DispatchQueue.main.async {
                            for (pk, count) in localCounts {
                                mutualCounts[pk, default: 0] += count
                            }
                        }
                        
                    } else if type == "EOSE" {
                        DispatchQueue.main.async {
                            eoseCount += 1
                            // We wait for all EOSEs from active connections, but multiple REQs per connection might send multiple EOSEs.
                            // To be safe, wait for relays.count * chunks EOSEs, or rely on timeout. Let's just rely on timeout + simple EOSE count for now.
                            // Actually, let's just trigger finish if we reach some EOSE threshold.
                            if eoseCount >= relays.count {
                                finish()
                            }
                        }
                    }
                }
                .store(in: &cancellables)

            c.$connectionState
                .receive(on: DispatchQueue.main)
                .sink { [weak self] state in
                    guard !completed, state == .connected, let self = self else { return }
                    
                    var current = 0
                    var chunkIndex = 0
                    // if empty, send empty filter just to trigger EOSE
                    if self.followedPubkeys.isEmpty {
                        let req = ["REQ", "ext-0", ["kinds": [3], "limit": 0]] as [Any]
                        if let data = try? JSONSerialization.data(withJSONObject: req), let str = String(data: data, encoding: .utf8) { c.send(text: str) }
                    }
                    
                    while current < self.followedPubkeys.count {
                        let end = min(current + 200, self.followedPubkeys.count)
                        let chunk = Array(self.followedPubkeys[current..<end])
                        let filter: [String: Any] = ["kinds": [3], "authors": chunk]
                        let req = ["REQ", "ext-\(chunkIndex)-\(UUID().uuidString.prefix(4))", filter] as [Any]
                        if let data = try? JSONSerialization.data(withJSONObject: req),
                           let str = String(data: data, encoding: .utf8) {
                            c.send(text: str)
                        }
                        current = end
                        chunkIndex += 1
                    }
                }
                .store(in: &cancellables)

            c.connect(url: url)
        }
    }

    // MARK: - Follow / Unfollow

    enum FollowActionError: Error {
        case contactsNotLoaded
        case alreadyFollowing
        case cannotUnfollowSelf
    }

    @discardableResult
    func followUser(_ pubkey: String) -> Result<Void, FollowActionError> {
        // Don't publish if contacts haven't loaded yet — would wipe the list
        guard hasAttemptedContactLoad, !isLoadingContacts else { return .failure(.contactsNotLoaded) }
        guard !followedPubkeys.contains(pubkey) else { return .failure(.alreadyFollowing) }
        followedPubkeys.append(pubkey)
        publishContactList()
        return .success(())
    }

    @discardableResult
    func unfollowUser(_ pubkey: String) -> Result<Void, FollowActionError> {
        // Don't publish if contacts haven't loaded yet — would wipe the list
        guard hasAttemptedContactLoad, !isLoadingContacts else { return .failure(.contactsNotLoaded) }
        let activeHex = ConfigService.shared.activeAccountHexPubkey
        guard pubkey != activeHex else { return .failure(.cannotUnfollowSelf) }
        followedPubkeys.removeAll { $0 == pubkey }
        publishContactList()
        return .success(())
    }

    private func publishContactList() {
        let tags = followedPubkeys.map { ["p", $0] }
        guard let event = NostrService.shared.signEvent(kind: 3, content: contactListContent, tags: tags) else { return }
        NostrService.shared.postEvent(event)
    }

    // MARK: - Feed Subscription (local + external in parallel)

    private var feedLoadingTimeout: Timer?

    private func subscribeToAllRelays() {
        if (feedMode == .following || (feedMode == .media && mediaFeedMode == .following)) && followedPubkeys.isEmpty {
            connectionStatus = "Follow someone on Nostr to see their posts here"
            return
        }
        if feedMode == .discovery && extendedNetworkPubkeys.isEmpty {
            connectionStatus = "Follow more people to build your discovery network"
            return
        }

        isLoadingFeed = true
        eoseCount = 0
        relayErrorCounts.removeAll()
        connectionStatus = "Loading feed…"

        // Disconnect any prior feed clients; account-switch path has already
        // done this, but switchMode + first-load go through here too.
        disconnectFeedClients()

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
                self.isSyncing = false
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
                            self.isSyncing = false
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
        let since = Int64(Date().timeIntervalSince1970) - (3 * 24 * 3600) // last 3 days
        let isGlobal = feedMode == .global || (feedMode == .media && mediaFeedMode == .global)
        let limitVal = feedMode == .media ? 150 : 75
        var filter: [String: Any] = [
            "kinds": [1, 6, 30023],
            "since": since,
            "limit": limitVal
        ]
        
        if feedMode == .following || (feedMode == .media && mediaFeedMode == .following) {
            filter["authors"] = followedPubkeys
        } else if feedMode == .discovery {
            filter["authors"] = extendedNetworkPubkeys
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

        let ownerHex = NostrService.shared.activeHexPubkey
        if !ownerHex.isEmpty {
            // Filter 2: Mentions (#p) of the owner (from anyone)
            var mentionsFilter = filter
            mentionsFilter["#p"] = [ownerHex]
            mentionsFilter["authors"] = nil // From anyone
            mentionsFilter["limit"] = 50
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
                "limit": 150
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
                "limit": 50
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
                "limit": 50
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
                    self.isSyncing = false
                    self.connectionStatus = "Live"
                }
            }
            return
        }

        // Intercept parent-note fetch responses from reused active connections.
        // These come back on the permanent feed pipeline but belong to the fast-path
        // handler so they appear in the thread preview immediately, bypassing the
        // 0.8 s note-flush timer.
        if type == "EVENT", json.count >= 2,
           let subId = json[1] as? String, subId.hasPrefix("tfetch-") {
            DispatchQueue.main.async { [weak self] in
                self?.handleParentNoteFetch(msg)
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

        // FeedNote.init handles kind 6 JSON embedding internally: it swaps to the inner
        // author/content/tags and sets repostedBy. Passing the raw event through is enough.
        let note = FeedNote(
            id: id,
            pubkey: pubkey,
            content: content,
            createdAt: Date(timeIntervalSince1970: TimeInterval(createdAt)),
            tags: tags,
            kind: kind,
            repostedBy: kind == 6 ? pubkey : nil
        )

        // Filter out obvious spam/noise from being processed
        if FeedNote.isNoiseOrSpam(content: note.content, tags: note.tags) {
            return
        }

        // NIP-18: Cache raw event JSON for repost embedding.
        // For kind 1/30023: serialize the full event dict (includes sig).
        // For kind 6 with embedded content: the content IS the inner event's JSON.
        var rawEntries: [(id: String, json: String)] = []
        if kind == 1 || kind == 30023 {
            if let data = try? JSONSerialization.data(withJSONObject: ev, options: []),
               let json = String(data: data, encoding: .utf8) {
                rawEntries.append((id: id, json: json))
            }
        }
        if kind == 6, !content.isEmpty,
           let innerData = content.data(using: .utf8),
           let inner = try? JSONSerialization.jsonObject(with: innerData) as? [String: Any],
           let innerId = inner["id"] as? String {
            rawEntries.append((id: innerId, json: content))
        }

        // Accumulate on processing queue — NO per-event main thread dispatch
        let acc = self.bgAccumulator
        processingQueue.async { [weak self] in
            acc.notes.append(note)
            acc.profiles.append(pubkey)
            acc.rawEventEntries.append(contentsOf: rawEntries)
            // After FeedNote.init swaps for kind 6 reposts, note.pubkey is the original author.
            // Fetch their profile too so the reposted card renders with the right name/avatar.
            if note.pubkey != pubkey { acc.profiles.append(note.pubkey) }

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

            // Parents are prefetched in applySnapshot (proactive, so they arrive before
            // the child row appears). Repost/quoted fetches still happen on onAppear.
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
        var parentIdsToFetch: [String] = []
        for note in snap.notes {
            guard !seenIds.contains(note.id) else { continue }
            seenIds.insert(note.id)
            noteBuffer.append(note)
            added = true
            // Prefetch parents proactively so they're cached before the row scrolls
            // into view — otherwise the child renders before the parent arrives.
            if let parentId = note.parentEventId {
                parentIdsToFetch.append(parentId)
            }
        }
        for parentId in parentIdsToFetch {
            fetchMissingNote(id: parentId)
        }

        let uniquePubkeys = Set(snap.profiles).subtracting(Set(NostrService.shared.profiles.keys))
        if !uniquePubkeys.isEmpty {
            NostrService.shared.fetchMissingProfiles(for: Array(uniquePubkeys))
        }

        // Process reaction events: self-like detection + per-note counting
        let hasEngagement = !snap.reactionEvents.isEmpty || !snap.replyTargets.isEmpty || !snap.repostTargets.isEmpty
        if hasEngagement {
            let ownerHex = NostrService.shared.activeHexPubkey

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

        // Merge raw event JSON entries into the cache for NIP-18 repost embedding
        if !snap.rawEventEntries.isEmpty {
            for entry in snap.rawEventEntries {
                rawEventCache[entry.id] = entry.json
            }
            // Cap cache size to prevent unbounded growth
            if rawEventCache.count > Self.maxRawEventCacheSize {
                let overflow = rawEventCache.count - Self.maxRawEventCacheSize
                let keysToRemove = Array(rawEventCache.keys.prefix(overflow))
                for key in keysToRemove { rawEventCache.removeValue(forKey: key) }
            }
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

        // Fan out to local + all external relays — first response wins, later ones
        // are dropped by handleParentNoteFetch's findNote guard. Local-only was too
        // slow because replies often reference notes from people you don't follow,
        // which are not mirrored on the local relay.
        var candidates: [URL] = []
        if let local = localRelayURL {
            candidates.append(local)
        }
        candidates.append(contentsOf: externalRelayURLs)

        #if DEBUG
        print("FeedService: Fetching \(ids.count) missing notes for threading")
        #endif

        for url in candidates {
            let subId = "tfetch-\(UUID().uuidString.prefix(6))"
            let filter: [String: Any] = ["ids": ids]
            let req = ["REQ", subId, filter] as [Any]
            guard let reqData = try? JSONSerialization.data(withJSONObject: req),
                  let reqStr = String(data: reqData, encoding: .utf8) else { continue }

            // Fast path: reuse an already-connected feed client for this relay.
            // This avoids a full TCP + TLS + WebSocket handshake (typically 1-3 s)
            // and delivers the parent note in milliseconds instead.
            if let activeClient = feedClients[url.absoluteString],
               activeClient.connectionState == .connected {
                activeClient.send(text: reqStr)

                // Schedule CLOSE to release the subscription on the relay after results arrive.
                let closeMsg = ["CLOSE", subId] as [Any]
                if let closeData = try? JSONSerialization.data(withJSONObject: closeMsg),
                   let closeStr = String(data: closeData, encoding: .utf8) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                        activeClient.send(text: closeStr)
                    }
                }

                #if DEBUG
                print("FeedService: tfetch reusing active connection → \(url.host ?? url.absoluteString)")
                #endif
                continue
            }

            // Fallback: open a temporary connection when no active one is available.
            let c = WebSocketClient()
            c.isTemporary = true

            // Temporary connections don't go through handleFeedMsgBackground, so
            // subscribe the fast-path handler directly on the message subject.
            c.messageSubject
                .receive(on: DispatchQueue.main)
                .sink { [weak self] msg in self?.handleParentNoteFetch(msg) }
                .store(in: &cancellables)

            c.$connectionState
                .receive(on: DispatchQueue.main)
                .sink { state in
                    if state == .connected {
                        c.send(text: reqStr)
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

        // Use findNote rather than seenIds: a note can be in seenIds but evicted from
        // notes[] by the 800-cap flush, in which case we still need it in parentNotesCache.
        guard findNote(id: id) == nil else { return }

        let note = FeedNote(
            id: id,
            pubkey: pubkey,
            content: content,
            createdAt: Date(timeIntervalSince1970: TimeInterval(createdAt)),
            tags: tags,
            kind: kind
        )

        guard !FeedNote.isNoiseOrSpam(content: note.content, tags: note.tags) else { return }

        // Cache raw event JSON for NIP-18 repost embedding
        if kind == 1 || kind == 30023 {
            if let evData = try? JSONSerialization.data(withJSONObject: ev, options: []),
               let evJSON = String(data: evData, encoding: .utf8) {
                rawEventCache[id] = evJSON
            }
        }

        fetchingNoteIds.remove(id)
        parentNotesCache[id] = note
        NostrService.shared.fetchMissingProfiles(for: [pubkey])
    }

    // MARK: - Per-Note Stats Fetch (NoteDetailView)

    /// Fetches accurate reply / repost / reaction / zap counts for a single note
    /// by querying all configured relays in parallel. Results are deduped by event
    /// ID so counts are never inflated when the same event arrives from multiple
    /// relays. Writes the final tally to `noteStats[noteId]` on the main thread.
    func fetchNoteStats(for noteId: String) {
        // Prefer local relay; only fall back to one external relay to cap data use.
        var allURLs: [URL] = []
        if let local = localRelayURL {
            allURLs.append(local)
        } else if let first = externalRelayURLs.first {
            allURLs.append(first)
        }
        guard !allURLs.isEmpty else { return }

        // Shared mutable state — all mutations happen on the main thread via
        // DispatchQueue.main.async so no locks are needed.
        var seenEventIds = Set<String>()
        var replies  = 0
        var reposts  = 0
        var reactions = 0
        var zaps     = 0
        var eoseReceived = 0
        // Each relay sends EOSE for each of the 4 subscriptions
        let expectedEOSE = allURLs.count * 4
        var finished = false
        var tempClients: [WebSocketClient] = []

        let finish: () -> Void = { [weak self] in
            guard let self = self, !finished else { return }
            finished = true
            tempClients.forEach { $0.disconnect() }
            var stats = self.noteStats[noteId] ?? NoteStats()
            stats.replies   = replies
            stats.reposts   = reposts
            stats.reactions = reactions
            stats.zaps      = zaps
            self.noteStats[noteId] = stats
        }

        // Safety timeout: finalize after 8 seconds regardless.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { finish() }

        let subPrefix = UUID().uuidString.prefix(6)

        for (i, url) in allURLs.enumerated() {
            let client = WebSocketClient()
            client.isTemporary = true
            tempClients.append(client)

            client.messageSubject
                .receive(on: DispatchQueue.main)
                .sink { msg in
                    guard !finished,
                          let data = msg.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
                          let type = json[0] as? String else { return }

                    if type == "EOSE" {
                        eoseReceived += 1
                        if eoseReceived >= expectedEOSE { finish() }
                        return
                    }

                    guard type == "EVENT", json.count >= 3,
                          let ev   = json[2] as? [String: Any],
                          let evId = ev["id"] as? String,
                          let kind = ev["kind"] as? Int,
                          !seenEventIds.contains(evId) else { return }

                    seenEventIds.insert(evId)

                    switch kind {
                    case 1:    replies   += 1
                    case 6:    reposts   += 1
                    case 7:    reactions += 1
                    case 9735: zaps      += 1
                    default:   break
                    }
                }
                .store(in: &cancellables)

            client.$connectionState
                .receive(on: DispatchQueue.main)
                .sink { state in
                    guard state == .connected, !finished else { return }
                    let p = "\(subPrefix)-\(i)"
                    let filters: [[String: Any]] = [
                        ["kinds": [1],    "#e": [noteId], "limit": 100],
                        ["kinds": [6],    "#e": [noteId], "limit": 100],
                        ["kinds": [7],    "#e": [noteId], "limit": 100],
                        ["kinds": [9735], "#e": [noteId], "limit": 100],
                    ]
                    for (fi, filter) in filters.enumerated() {
                        let req = ["REQ", "\(p)-\(fi)", filter] as [Any]
                        if let reqData = try? JSONSerialization.data(withJSONObject: req),
                           let reqStr  = String(data: reqData, encoding: .utf8) {
                            client.send(text: reqStr)
                        }
                    }
                }
                .store(in: &cancellables)

            client.connect(url: url)
        }
    }
}
