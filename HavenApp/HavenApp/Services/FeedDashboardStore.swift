import Foundation
import Combine

/// The feed dashboard: what the people you follow did in the last 24 hours.
///
/// One load asks each kind's usual relays once, all filtered to your follows
/// and the last day, and derives every card from that one result. It does not
/// start the Live, Marketplace or diVines services, so opening the dashboard
/// never changes what those feeds show. Results are kept in memory and reused
/// for a few minutes, like the mode feeds.
@MainActor
final class FeedDashboardStore: ObservableObject {
    static let shared = FeedDashboardStore()

    @Published private(set) var snapshot: FeedDashboardSnapshot?
    @Published private(set) var isLoading = false
    /// True when the owner follows nobody, so there is nothing to show.
    @Published private(set) var followSetIsEmpty = false

    private var loadedAt: Date?
    private var loadedAccount: String?
    private var generation = 0

    static let window: TimeInterval = 24 * 60 * 60
    private static let staleAfter: TimeInterval = 5 * 60
    /// Relays reject very large author lists.
    private static let authorsPerFilter = 500

    private init() {}

    func loadIfNeeded() {
        if isLoading { return }
        let account = FeedService.shared.currentSnapshotKey()
        if let loadedAt, loadedAccount == account, snapshot != nil,
           Date().timeIntervalSince(loadedAt) < Self.staleAfter { return }
        refresh()
    }

    func refresh() {
        generation += 1
        let gen = generation
        let account = FeedService.shared.currentSnapshotKey()
        if loadedAccount != account { snapshot = nil }
        let follows = FeedService.shared.followedPubkeys
        followSetIsEmpty = follows.isEmpty
        let owner = ConfigService.shared.activeAccountHexPubkey
        guard !follows.isEmpty || !owner.isEmpty else { return }
        isLoading = true

        let since = Int(Date().timeIntervalSince1970 - Self.window)
        let config = ConfigService.shared.config
        let feedRelays = Self.urls(config.activeFeedRelays, cap: 6)
        let ownRelays = Self.urls([config.nostrURL] + config.readRelays, cap: 6)
        let marketRelays = Self.urls(MarketplaceFeedService.relayStrings, cap: 6)
        let liveRelays = Array(LiveFeedService.relayURLs.prefix(6))
        let chunks = stride(from: 0, to: follows.count, by: Self.authorsPerFilter).map {
            Array(follows[$0..<min($0 + Self.authorsPerFilter, follows.count)])
        }
        func byFollows(_ kinds: [Int], limit: Int) -> [[String: Any]] {
            chunks.map { ["kinds": kinds, "authors": $0, "since": since, "limit": limit] }
        }

        Task {
            async let notes = follows.isEmpty ? [] : ZapHistoryService.query(
                filters: byFollows([1, 6], limit: 1500) + byFollows([7], limit: 1500)
                    + byFollows([FeedDashboardSnapshot.pollKind, FeedDashboardSnapshot.articleKind,
                                 FeedDashboardSnapshot.diVineKind], limit: 200),
                relays: feedRelays, timeout: 8)
            async let listings = follows.isEmpty ? [] : ZapHistoryService.query(
                filters: byFollows(MarketListing.kinds, limit: 100), relays: marketRelays, timeout: 8)
            async let live = follows.isEmpty ? [] : ZapHistoryService.query(
                filters: byFollows([FeedDashboardSnapshot.liveKind], limit: 100)
                    + chunks.map { ["kinds": [FeedDashboardSnapshot.liveKind], "#p": $0, "since": since, "limit": 100] },
                relays: liveRelays, timeout: 8)
            async let zaps = owner.isEmpty ? [] : ZapHistoryService.query(
                filters: [["kinds": [9735], "#p": [owner], "since": since, "limit": 500]],
                relays: ownRelays, timeout: 8)
            let followers = await Task.detached(priority: .utility) {
                FollowerSnapshot.load(owner: owner)
            }.value

            let events = await notes + listings + live
            let zapEvents = await zaps
            guard gen == self.generation else { return }

            let built = FeedDashboardSnapshot.build(
                events: events,
                zapReceipts: zapEvents,
                followers: followers,
                follows: Set(follows),
                owner: owner,
                blocked: ConfigService.shared.activeAccountBlockedHexPubkeys,
                since: Int64(since),
                now: Int64(Date().timeIntervalSince1970))
            self.snapshot = built
            self.loadedAt = Date()
            self.loadedAccount = account
            self.isLoading = false
            await self.fetchPopularNotes(built, relays: feedRelays, generation: gen)
            NostrService.shared.fetchMissingProfiles(for: built.profilePubkeys)
        }
    }

    /// The most-liked posts are often older than a day, or by someone you do
    /// not follow: fetch the ones the load did not already bring.
    private func fetchPopularNotes(_ built: FeedDashboardSnapshot, relays: [URL], generation gen: Int) async {
        let missing = built.popular.filter { $0.note == nil }.map(\.id)
        guard !missing.isEmpty else { return }
        let found = await ZapHistoryService.query(
            filters: [["ids": missing, "limit": missing.count]], relays: relays, timeout: 6)
        guard gen == generation, var current = snapshot else { return }
        current.attachPopularNotes(found)
        snapshot = current
        NostrService.shared.fetchMissingProfiles(for: current.profilePubkeys)
    }

    /// A tile or stat opens its feed on Following: the dashboard is about
    /// the people you follow, so Global would show something else.
    static func openOnFollowing(_ mode: FeedMode) {
        let feed = FeedService.shared
        switch mode {
        case .polls where feed.feedMode == .polls: PollsFeed.setScope(.following)
        case .polls: feed.pollsFeedMode = .following
        case .marketplace: MarketplaceFeedService.shared.setScope(.following)
        case .reels: ReelsFeedService.shared.setScope(.following)
        case .recipes: RecipeFeedService.shared.setScope(.following)
        case .live: LiveFeedService.shared.setScope(.following)
        default: break
        }
        if feed.feedMode != mode { feed.switchMode(mode) }
    }

    private static func urls(_ strings: [String], cap: Int) -> [URL] {
        var seen = Set<String>()
        return strings
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))).inserted }
            .prefix(cap)
            .compactMap(URL.init(string:))
    }
}

/// Every card's numbers, derived from one load. Pure, so it is unit-testable.
struct FeedDashboardSnapshot: Equatable {
    static let pollKind = 1068
    static let articleKind = 30023
    static let diVineKind = 34236
    static let liveKind = 30311

    struct Ranked: Equatable, Identifiable {
        let id: String
        let count: Int
    }

    struct PopularNote: Equatable, Identifiable {
        let id: String
        /// Distinct follows who liked, reposted or quoted it.
        let people: Int
        var note: FeedNote?
    }

    struct Tile: Equatable, Identifiable {
        let mode: FeedMode
        let count: Int
        /// One line from the newest item.
        let preview: String?
        var id: String { mode.rawValue }
    }

    // Stats
    var posts = 0
    var activePeople = 0
    var satsReceived = 0
    var newFollowers = 0

    var live: [LiveStream] = []
    /// Authors by post count, most first.
    var mostActive: [Ranked] = []
    var popular: [PopularNote] = []
    /// Hashtags by how many follows used them.
    var trending: [Ranked] = []
    var tiles: [Tile] = []

    /// Everyone the cards draw an avatar or a name for.
    var profilePubkeys: [String] {
        var keys = mostActive.prefix(12).map(\.id)
        keys += live.map(\.hostPubkey)
        keys += popular.compactMap { $0.note?.pubkey }
        return Array(Set(keys))
    }

    var isEmpty: Bool {
        posts == 0 && satsReceived == 0 && newFollowers == 0 && live.isEmpty && tiles.isEmpty && popular.isEmpty
    }

    mutating func attachPopularNotes(_ events: [[String: Any]]) {
        let notes = Dictionary(events.compactMap(Self.note(from:)).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for i in popular.indices where popular[i].note == nil {
            popular[i].note = notes[popular[i].id]
        }
        popular.removeAll { $0.note == nil }
    }

    static func build(events: [[String: Any]], zapReceipts: [[String: Any]], followers: FollowerSnapshot?,
                      follows: Set<String>, owner: String, blocked: Set<String>,
                      since: Int64, now: Int64) -> FeedDashboardSnapshot {
        var s = FeedDashboardSnapshot()
        var seen = Set<String>()
        var postsBy: [String: Int] = [:]
        var tagPeople: [String: Set<String>] = [:]
        var likedBy: [String: Set<String>] = [:]
        var notesById: [String: FeedNote] = [:]
        var polls: [FeedNote] = [], articles: [FeedNote] = [], recipes: [FeedNote] = []
        var diVines: [FeedNote] = [], listings: [MarketListing] = [], music: [FeedNote] = []
        var liveByAddress: [String: LiveStream] = [:]

        for event in events {
            guard let id = event["id"] as? String, seen.insert(id).inserted,
                  let pubkey = event["pubkey"] as? String, !blocked.contains(pubkey),
                  let kind = event["kind"] as? Int,
                  let createdAt = (event["created_at"] as? NSNumber)?.int64Value else { continue }
            let tags = event["tags"] as? [[String]] ?? []
            let content = event["content"] as? String ?? ""

            if kind == liveKind {
                // Hosted on a service, a stream's author is the service; the
                // host is in a `p` tag. Either one being followed counts.
                guard let stream = LiveStream(id: id, pubkey: pubkey, createdAt: createdAt, tags: tags),
                      follows.contains(stream.hostPubkey) || follows.contains(pubkey),
                      !blocked.contains(stream.hostPubkey),
                      stream.isPlayableLive(at: now) else { continue }
                if let old = liveByAddress[stream.address], old.createdAt >= stream.createdAt { continue }
                liveByAddress[stream.address] = stream
                continue
            }
            guard follows.contains(pubkey), createdAt >= since else { continue }

            switch kind {
            case 1, 6:
                s.posts += 1
                postsBy[pubkey, default: 0] += 1
                if kind == 1 {
                    let note = FeedNote(id: id, pubkey: pubkey, content: content,
                                        createdAt: Date(timeIntervalSince1970: TimeInterval(createdAt)),
                                        tags: tags, kind: kind, repostedBy: nil)
                    notesById[id] = note
                    for tag in tags where tag.count >= 2 && tag[0] == "t" {
                        let t = tag[1].lowercased().trimmingCharacters(in: .whitespaces)
                        if !t.isEmpty, t.count <= 40 { tagPeople[t, default: []].insert(pubkey) }
                    }
                    for tag in tags where tag.count >= 2 && tag[0] == "q" { likedBy[tag[1], default: []].insert(pubkey) }
                    if containsWavlakeTrack(content) { music.append(note) }
                } else if let target = lastTag("e", in: tags) {
                    likedBy[target, default: []].insert(pubkey)
                }
            case 7:
                if content != "-", let target = lastTag("e", in: tags) {
                    likedBy[target, default: []].insert(pubkey)
                }
            case pollKind:
                polls.append(feedNote(id, pubkey, content, createdAt, tags, kind))
            case articleKind:
                let note = feedNote(id, pubkey, content, createdAt, tags, kind)
                let topics = Set(tags.filter { $0.count >= 2 && $0[0] == "t" }.map { $0[1].lowercased() })
                if !topics.isDisjoint(with: RecipeFeedService.recipeTopics) { recipes.append(note) } else { articles.append(note) }
            case diVineKind:
                diVines.append(feedNote(id, pubkey, content, createdAt, tags, kind))
            case let k where MarketListing.kinds.contains(k):
                if let listing = MarketListing(id: id, pubkey: pubkey, kind: kind, content: content,
                                               createdAt: Date(timeIntervalSince1970: TimeInterval(createdAt)), tags: tags) {
                    listings.append(listing)
                }
            default:
                break
            }
        }

        s.activePeople = postsBy.count
        s.mostActive = postsBy.map { Ranked(id: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.id < $1.id }
        // Two people make a trend; one person's tag is just their tag.
        s.trending = tagPeople.filter { $0.value.count >= 2 }
            .map { Ranked(id: $0.key, count: $0.value.count) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.id < $1.id }
            .prefix(10).map { $0 }
        s.popular = likedBy.filter { $0.value.count >= 2 }
            .map { PopularNote(id: $0.key, people: $0.value.count, note: notesById[$0.key]) }
            .sorted { $0.people != $1.people ? $0.people > $1.people : $0.id < $1.id }
            .prefix(3).map { $0 }
        s.live = liveByAddress.values.sorted { ($0.participants ?? 0, $0.createdAt) > ($1.participants ?? 0, $1.createdAt) }

        // A listing edited twice in a day is still one listing.
        var listingAddresses = Set<String>()
        listings = listings.sorted { $0.createdAt > $1.createdAt }.filter { listingAddresses.insert("\($0.kind):\($0.pubkey):\($0.dTag ?? $0.id)").inserted }

        func tile(_ mode: FeedMode, _ notes: [FeedNote], _ preview: (FeedNote) -> String?) -> Tile? {
            let sorted = notes.sorted { $0.createdAt > $1.createdAt }
            guard let first = sorted.first else { return nil }
            return Tile(mode: mode, count: sorted.count, preview: preview(first))
        }
        let title: (FeedNote) -> String? = { note in
            firstTag("title", in: note.tags) ?? firstTag("alt", in: note.tags) ?? oneLine(note.content)
        }
        s.tiles = [
            tile(.polls, polls) { oneLine($0.content) },
            listings.first.map { Tile(mode: .marketplace, count: listings.count, preview: $0.title) },
            tile(.articles, articles, title),
            tile(.reels, diVines, title),
            tile(.recipes, recipes, title),
            tile(.music, music) { _ in nil },
        ].compactMap { $0 }

        // Sats: each receipt counted once; an unreadable invoice counts nothing.
        for receipt in zapReceipts {
            guard (receipt["kind"] as? Int) == 9735,
                  let created = (receipt["created_at"] as? NSNumber)?.int64Value, created >= since,
                  let tags = receipt["tags"] as? [[String]],
                  tags.contains(where: { $0.count >= 2 && $0[0] == "p" && $0[1] == owner }),
                  let bolt11 = firstTag("bolt11", in: tags),
                  case .sats(let sats) = Bolt11.amount(bolt11) else { continue }
            s.satsReceived += sats
        }

        // The relay's ledger, not raw kind 3s: a refollow bot republishing
        // its list is not a new follower (#393).
        if let followers {
            s.newFollowers = followers.current.filter { $0.isNews && $0.followedAt >= since }.count
        }
        return s
    }

    private static func feedNote(_ id: String, _ pubkey: String, _ content: String, _ createdAt: Int64,
                                 _ tags: [[String]], _ kind: Int) -> FeedNote {
        FeedNote(id: id, pubkey: pubkey, content: content,
                 createdAt: Date(timeIntervalSince1970: TimeInterval(createdAt)),
                 tags: tags, kind: kind, repostedBy: nil)
    }

    static func note(from event: [String: Any]) -> FeedNote? {
        guard let id = event["id"] as? String, let pubkey = event["pubkey"] as? String,
              let kind = event["kind"] as? Int,
              let createdAt = (event["created_at"] as? NSNumber)?.int64Value else { return nil }
        return feedNote(id, pubkey, event["content"] as? String ?? "", createdAt, event["tags"] as? [[String]] ?? [], kind)
    }

    /// NIP-10: the last `e` tag is the one being replied to or reacted to.
    private static func lastTag(_ name: String, in tags: [[String]]) -> String? {
        tags.last { $0.count >= 2 && $0[0] == name && $0[1].count == 64 }?[1]
    }

    private static func firstTag(_ name: String, in tags: [[String]]) -> String? {
        tags.first { $0.count >= 2 && $0[0] == name && !$0[1].isEmpty }?[1]
    }

    private static func oneLine(_ text: String) -> String? {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return line.isEmpty ? nil : String(line.prefix(80))
    }

    private static func containsWavlakeTrack(_ content: String) -> Bool {
        guard content.contains("wavlake.com") else { return false }
        return content.split(whereSeparator: \.isWhitespace).contains { word in
            guard let url = URL(string: String(word)) else { return false }
            return WavlakeLink.trackId(from: url) != nil
        }
    }
}
