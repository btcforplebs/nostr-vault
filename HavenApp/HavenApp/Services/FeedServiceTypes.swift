import Foundation
import CoreGraphics

// MARK: - Models

/// Lightweight engagement counts per note, populated from relay data.
struct NoteStats: Equatable, Codable {
    var reactions: Int = 0
    var reposts: Int = 0
    var zaps: Int = 0
}

/// JSON result from the Go DVM's ComputePopularNotesC function.
struct PopularNoteResult: Codable {
    let id: String
    let pubkey: String
    let content: String
    let created_at: Int64
    let tags: [[String]]
    let kind: Int
    let score: Double
}

struct FeedNote: Identifiable, Hashable, Equatable, Codable {
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
    let linkURLs: [URL]
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
        self.parentEventId = kind != 6 ? NIP10Thread.parentEventId(kind: kind, tags: resolvedTags) : nil

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
        self.linkURLs = Self.parseLinkURLs(from: resolvedContent, excludingMedia: self.mediaURLs)
        self.quotedEventIds = Self.parseQuotedEventIds(from: resolvedContent)
        MediaHints.shared.register(tags: resolvedTags)
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

    private static let mediaRegex: NSRegularExpression? = SupportedMediaFormats.mediaExtensionRegex

    /// Matches extensionless Blossom URLs where the path is a 64-char SHA-256 hex hash.
    private static let blossomRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"https?://\S+/[a-f0-9]{64}(?=\s|$)"#, options: .caseInsensitive)
    }()

    /// Matches any HTTP(S) URL in content for link preview extraction.
    private static let httpURLRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"https?://[^\s<>\")\]]*[^\s<>\")\].,;:!?'\"]"#, options: .caseInsensitive)
    }()

    private static func parseMediaURLs(from content: String) -> [URL] {
        let ns = content as NSString
        let range = NSRange(location: 0, length: ns.length)
        var urls: [URL] = []

        if let regex = mediaRegex {
            urls += regex.matches(in: content, range: range)
                .compactMap { URL(string: ns.substring(with: $0.range)) }
        }

        // Extensionless Blossom URLs (SHA-256 hash as last path component)
        if let regex = blossomRegex {
            urls += regex.matches(in: content, range: range)
                .compactMap { URL(string: ns.substring(with: $0.range)) }
        }

        return urls
    }

    private static func parseQuotedEventIds(from content: String) -> [String] {
        QuoteReference.resolvedIdentifiers(in: content)
    }

    /// Extracts non-media HTTP(S) URLs from content for link preview cards.
    private static func parseLinkURLs(from content: String, excludingMedia mediaURLs: [URL]) -> [URL] {
        guard let regex = httpURLRegex else { return [] }
        let ns = content as NSString
        let range = NSRange(location: 0, length: ns.length)
        let mediaSet = Set(mediaURLs.map { $0.absoluteString })

        var seen = Set<String>()
        return regex.matches(in: content, range: range)
            .compactMap { URL(string: ns.substring(with: $0.range)) }
            .filter { !mediaSet.contains($0.absoluteString) }
            .filter { seen.insert($0.absoluteString).inserted }
    }

    // MARK: - Codable (encodes resolved properties to avoid NIP-18 double-resolution on decode)

    enum CodingKeys: String, CodingKey {
        case id, pubkey, content, createdAt, tags, kind, repostedBy
        case isReply, replyToPubkey, parentEventId, mediaURLs, linkURLs, quotedEventIds, repostedEventId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.pubkey = try c.decode(String.self, forKey: .pubkey)
        self.content = try c.decode(String.self, forKey: .content)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.tags = try c.decode([[String]].self, forKey: .tags)
        self.kind = try c.decode(Int.self, forKey: .kind)
        self.repostedBy = try c.decodeIfPresent(String.self, forKey: .repostedBy)
        self.isReply = try c.decode(Bool.self, forKey: .isReply)
        self.replyToPubkey = try c.decodeIfPresent(String.self, forKey: .replyToPubkey)
        self.parentEventId = try c.decodeIfPresent(String.self, forKey: .parentEventId)
        self.mediaURLs = try c.decode([URL].self, forKey: .mediaURLs)
        self.linkURLs = try c.decodeIfPresent([URL].self, forKey: .linkURLs) ?? []
        self.quotedEventIds = try c.decode([String].self, forKey: .quotedEventIds)
        self.repostedEventId = try c.decodeIfPresent(String.self, forKey: .repostedEventId)
        MediaHints.shared.register(tags: tags)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(pubkey, forKey: .pubkey)
        try c.encode(content, forKey: .content)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(tags, forKey: .tags)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(repostedBy, forKey: .repostedBy)
        try c.encode(isReply, forKey: .isReply)
        try c.encodeIfPresent(replyToPubkey, forKey: .replyToPubkey)
        try c.encodeIfPresent(parentEventId, forKey: .parentEventId)
        try c.encode(mediaURLs, forKey: .mediaURLs)
        try c.encode(linkURLs, forKey: .linkURLs)
        try c.encode(quotedEventIds, forKey: .quotedEventIds)
        try c.encodeIfPresent(repostedEventId, forKey: .repostedEventId)
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
        
        // 3. Hashtag or Mention stuffing (in very short content). Skip the mention
        // half of this check for replies: NIP-10 has them correctly carry a p-tag
        // for every thread participant (so everyone gets notified), which easily
        // exceeds this threshold in a busy thread — that's normal protocol
        // structure, not spam, and hiding it made people's own replies vanish
        // from thread views.
        let hashtags = tags.filter { $0.count >= 2 && $0[0] == "t" }
        let eTags = tags.filter { $0.count >= 2 && $0[0] == "e" }
        let isReply = eTags.contains { tag in
            guard tag.count >= 4 else { return true }
            return tag[3] != "mention"
        }
        let mentions = tags.filter { $0.count >= 2 && $0[0] == "p" }
        if trimmed.count < 100 {
            if hashtags.count > 6 || (!isReply && mentions.count > 6) {
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

// MARK: - Thread grouping

/// `FeedNote` already carries everything the thread grouper needs; this just
/// names `pubkey` the way the protocol does, so the grouping logic can be unit
/// tested against a plain fixture instead of a live note.
extension FeedNote: ThreadGroupable {
    var authorPubkey: String { pubkey }
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
    /// Note IDs that were reposted (from kind 6 events).
    var repostTargets: [String] = []
    /// Raw event JSON strings for NIP-18 repost embedding (id → stringified JSON with sig).
    var rawEventEntries: [(id: String, json: String)] = []
    var flushScheduled = false

    /// Dedup set for engagement events (reactions, etc.) to avoid double-counting
    /// from multiple relays. NOT drained — persists across flushes.
    var seenEngagementIds = Set<String>()
    private static let maxEngagementIds = 20_000

    /// When each lookup response id was last verified. Every relay asked
    /// answers with the same note; only the first valid copy is worth a
    /// signature check. Entries lapse after a few seconds so a later re-fetch of the
    /// same note (after a cache trim or feed switch) is verified again.
    private var parentFetchClaims: [String: Date] = [:]
    private static let parentFetchClaimWindow: TimeInterval = 10

    /// True if a copy of `id` already passed verification within the window.
    func parentFetchRecentlyVerified(_ id: String, now: Date = Date()) -> Bool {
        guard let at = parentFetchClaims[id] else { return false }
        return now.timeIntervalSince(at) < Self.parentFetchClaimWindow
    }

    /// Record that a copy of `id` passed verification. Only valid copies are
    /// recorded, so a relay answering first with a forgery cannot shadow the
    /// genuine note.
    func markParentFetchVerified(_ id: String, now: Date = Date()) {
        if parentFetchClaims.count > 2_000 {
            parentFetchClaims = parentFetchClaims.filter {
                now.timeIntervalSince($0.value) < Self.parentFetchClaimWindow
            }
        }
        parentFetchClaims[id] = now
    }

    func forgetParentFetch(_ id: String) { parentFetchClaims[id] = nil }

    func resetParentFetchClaims() { parentFetchClaims.removeAll() }

    static let flushIntervalFast: TimeInterval = 0.2
    static let flushIntervalNormal: TimeInterval = 0.5
    static let flushIntervalRealtime: TimeInterval = 0.05

    /// During initial feed load, flush more frequently so content appears sooner.
    /// Set to true by FeedService when subscribeToAllRelays starts; false on EOSE.
    var isInitialLoad = false

    /// Global feed mode uses ultra-fast flushing for real-time streaming.
    /// Set to true when feedMode is .global or media+global.
    var isGlobalMode = false

    var effectiveFlushInterval: TimeInterval {
        if isGlobalMode { return Self.flushIntervalRealtime }
        return isInitialLoad ? Self.flushIntervalFast : Self.flushIntervalNormal
    }

    struct Snapshot {
        let notes: [FeedNote]
        let profiles: [String]
        let reactionEvents: [(targetId: String, pubkey: String)]
        let repostTargets: [String]
        let rawEventEntries: [(id: String, json: String)]
    }

    func drain() -> Snapshot {
        let snap = Snapshot(
            notes: notes,
            profiles: profiles,
            reactionEvents: reactionEvents,
            repostTargets: repostTargets,
            rawEventEntries: rawEventEntries
        )
        notes.removeAll(keepingCapacity: true)
        profiles.removeAll(keepingCapacity: true)
        reactionEvents.removeAll(keepingCapacity: true)
        repostTargets.removeAll(keepingCapacity: true)
        rawEventEntries.removeAll(keepingCapacity: true)
        flushScheduled = false

        // Cap dedup set to prevent unbounded growth. Evict roughly half rather
        // than clearing entirely so recent IDs still suppress duplicates.
        // Sort before evicting so every device drops the same (lexicographically smallest) IDs.
        if seenEngagementIds.count > Self.maxEngagementIds {
            let keepCount = Self.maxEngagementIds / 2
            let sorted = seenEngagementIds.sorted(by: >)
            seenEngagementIds = Set(sorted.prefix(keepCount))
        }
        return snap
    }
}

// MARK: - FeedService

enum MediaFeedMode: String, CaseIterable {
    case following = "Following"
    case global = "Global"
}

/// Filter for the Popular feed: show all, only follows, or only non-follows.
enum PopularFilter: String, CaseIterable {
    case all = "All"
    case follows = "Follows"
    case nonFollows = "Non-Follows"
}

/// Feed mode: following (contacts only), discovery (extended network), global (all notes), popular (trending), media grid, or articles (long-form from follows).
enum FeedMode: String, CaseIterable {
    case following = "Following"
    case discovery = "Discovery"
    case global = "Global"
    case popular = "Popular"
    case media = "Media"
    case reels = "Reels"
    case articles = "Articles"
    case recipes = "Recipes"
    case live = "Live"
}

extension FeedMode {
    /// Name shown in the feed picker and the top bar.
    var displayName: String {
        switch self {
        case .discovery: return "Discover"
        case .reels: return "diVines"
        default: return rawValue
        }
    }

    /// Icon for the feed picker and the top bar. Popular, Articles, Recipes
    /// and Live match their empty-state icons.
    var symbolName: String {
        switch self {
        case .following: return "person.2"
        case .discovery: return "sparkles"
        case .global: return "globe"
        case .popular: return "flame"
        case .media: return "photo.on.rectangle"
        case .reels: return "play.rectangle"
        case .articles: return "doc.richtext"
        case .recipes: return "fork.knife"
        case .live: return "dot.radiowaves.left.and.right"
        }
    }
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
    var contactListContent: String = ""
    var contactListPTags: [[String]] = []
    var lastFetchedContactCount: Int = 0
    var hasAttemptedContactLoad: Bool = false
    var capturedAt: Date = Date()
    var lastEventTimestamp: Int64 = 0
}

/// Lightweight, Codable subset of AccountFeedSnapshot persisted to disk so that
/// switching to a previously-visited account after app restart doesn't require a
/// full cold load. Excludes parentNotesCache (large, re-fetched lazily), seenIds
/// (rebuilt from notes), and interaction state (already persisted separately).
struct DiskFeedSnapshot: Codable {
    var notes: [FeedNote]
    var followedPubkeys: [String]
    var extendedNetworkPubkeys: [String]
    var noteStats: [String: NoteStats]
    var contactListContent: String
    var contactListPTags: [[String]]
    var lastFetchedContactCount: Int
    var capturedAt: Date
    var lastEventTimestamp: Int64 = 0
    /// `created_at` of the contact list last published/committed locally.
    /// Optional so existing snapshots (written before this field) still decode.
    var ownContactListCreatedAt: Int64?

    /// Snapshots older than 7 days are considered stale.
    static let maxAge: TimeInterval = 7 * 24 * 60 * 60
}

/// Emitted when notes that other rows *reference* (thread parents, kind-6
/// originals, quoted notes) arrive from a relay and land in
/// `FeedService.parentNotesCache`. The feed's row-data cache is keyed by the
/// referencing note's id, so an arriving reference changes no row's own id and
/// no other published property — without this signal the row keeps rendering
/// its skeleton until something unrelated (a new note, a profile, a like)
/// happens to force a re-resolve.
///
/// `generation` makes two consecutive batches with identical ids distinct, so
/// `onChange` still fires.
struct ReferencedNoteSignal: Equatable {
    var generation: Int = 0
    var ids: Set<String> = []
}

extension FeedNote: ReferencedNoteRow {
    /// NIP-10 root marker. nil for a root note and for a legacy reply that
    /// carries no marked `e` tag — in both cases the parent edge is enough.
    var threadRootEventId: String? {
        tags.first { $0.count >= 4 && $0[0] == "e" && $0[3] == "root" }?[1]
    }
}

// MARK: - NIP-92 media hints

/// What a note's `imeta` tag says about a media URL before any byte of it
/// downloads: pixel size, MIME type, blurhash.
struct MediaHint: Equatable {
    var size: CGSize?
    var mime: String?
    var blurhash: String?

    /// width / height, when the note published a usable `dim`.
    var aspectRatio: CGFloat? {
        guard let size, size.width > 0, size.height > 0 else { return nil }
        return size.width / size.height
    }
}

/// URL-keyed store of `imeta` hints, filled as feed notes are built. Media
/// views read it to reserve a photo's real height up front (so the row does not
/// resize when the image lands) and to classify extensionless uploads without a
/// HEAD request. Keyed by URL rather than stored on `FeedNote` so every view
/// that renders a URL benefits without threading the note through.
final class MediaHints: @unchecked Sendable {
    static let shared = MediaHints()

    private final class Box {
        let hint: MediaHint
        init(_ hint: MediaHint) { self.hint = hint }
    }

    private let cache: NSCache<NSURL, Box> = {
        let cache = NSCache<NSURL, Box>()
        cache.countLimit = 4000
        return cache
    }()

    func hint(for url: URL) -> MediaHint? {
        cache.object(forKey: url as NSURL)?.hint
    }

    func register(tags: [[String]]) {
        for tag in tags where tag.first == "imeta" {
            guard let (url, hint) = Self.parse(imeta: tag) else { continue }
            cache.setObject(Box(hint), forKey: url as NSURL)
        }
    }

    /// Parses one flat NIP-92 tag: `["imeta", "url …", "dim 1920x1080", "m image/jpeg", …]`.
    /// Returns nil when the tag has no URL or carries nothing useful.
    static func parse(imeta tag: [String]) -> (URL, MediaHint)? {
        var url: URL?
        var hint = MediaHint()
        for field in tag.dropFirst() {
            guard let space = field.firstIndex(of: " ") else { continue }
            let key = field[..<space]
            let value = field[field.index(after: space)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "url":
                url = URL(string: value)
            case "dim":
                let parts = value.lowercased().split(separator: "x")
                if parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]), w > 0, h > 0 {
                    hint.size = CGSize(width: w, height: h)
                }
            case "m":
                if !value.isEmpty { hint.mime = value }
            case "blurhash":
                if !value.isEmpty { hint.blurhash = value }
            default:
                continue
            }
        }
        guard let url, hint != MediaHint() else { return nil }
        return (url, hint)
    }
}
