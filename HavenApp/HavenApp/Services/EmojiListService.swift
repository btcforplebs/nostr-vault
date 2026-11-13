import Foundation
import Combine

/// The account's own custom emoji, read from Nostr: the newest kind 10030
/// (NIP-51), its single `emoji` tags, and the 30030 sets its `a` tags add.
/// Cached on disk so the picker has them at once; refreshed at launch and
/// whenever the picker opens. Adding or removing a set (the Vault's Emoji
/// page) is `EmojiVaultStore.setListed`. Android: `service/EmojiListRepository.kt`.
@MainActor
final class EmojiListService: ObservableObject {
    static let shared = EmojiListService()

    @Published private(set) var library = EmojiLibrary()
    /// The signed 30030 behind each set in `library`, by address, from the
    /// last refresh (not cached): the Emoji page resends and keeps these.
    private(set) var setEvents: [String: NostrEvent] = [:]
    /// The 10030 the library was read from, for the Emoji page's edits.
    private(set) var listEvent: NostrEvent?

    /// Set by `FeedActions.make`, the one place every screen's actions come from.
    weak var nostrService: NostrService?

    private var refreshing: Task<Void, Never>?
    /// Bumped per read; only the newest read's answer is kept.
    private var generation = 0
    private var lastRefresh = Date.distantPast
    /// How old the library may get before `refresh()` asks again. Every
    /// screen's `FeedActions.make` calls it, and a SwiftUI view re-creates
    /// its actions on each redraw, so at once a minute an idle app opened
    /// ten relay sockets a minute for this alone (sweep 2026-11-01). The
    /// picker opening asks with `pickerMaxAge`.
    static let refreshEvery: TimeInterval = 30 * 60
    static let pickerMaxAge: TimeInterval = 60
    /// Sets read per refresh (the Emoji page lists them all; was 20 for the
    /// picker alone). Fetched together, `setsPerRequest` to a REQ.
    static let maxSets = 100
    private static let setsPerRequest = 50

    private var cacheURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("emoji_library.json")
    }

    init() {
        if let url = cacheURL, let data = try? Data(contentsOf: url),
           let cached = try? JSONDecoder().decode(EmojiLibrary.self, from: data) {
            library = cached
        }
    }

    /// Asks the relays again when the library is older than `maxAge`. Shows
    /// nothing of another account's.
    func refresh(maxAge: TimeInterval = refreshEvery) {
        // Saved copies draw first everywhere an emoji shows.
        EmojiVaultStore.shared.useActiveAccount()
        guard let nostrService else { return }
        let owner = nostrService.activeHexPubkey
        guard !owner.isEmpty else { return }
        if !library.owner.isEmpty, library.owner != owner {
            library = EmojiLibrary(owner: owner)
            setEvents = [:]
            listEvent = nil
        }
        guard refreshing == nil, Date().timeIntervalSince(lastRefresh) >= maxAge else { return }
        lastRefresh = Date()
        generation &+= 1
        let ticket = generation
        refreshing = Task { [weak self] in
            let loaded = await Self.load(owner: owner, nostrService: nostrService)
            guard let self, self.generation == ticket else { return }
            self.refreshing = nil
            guard let loaded, nostrService.activeHexPubkey == owner else { return }
            self.setEvents = loaded.events
            self.listEvent = loaded.list
            self.library = loaded.library
            if let url = self.cacheURL, let data = try? JSONEncoder().encode(loaded.library) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    /// Refresh now, whatever the library's age (after an add or remove): a
    /// read already under way is dropped, since it may predate the change.
    func refreshNow() {
        refreshing?.cancel()
        refreshing = nil
        lastRefresh = .distantPast
        refresh(maxAge: 0)
    }

    private struct Loaded {
        let library: EmojiLibrary
        let list: NostrEvent
        let events: [String: NostrEvent]
    }

    private static func load(owner: String, nostrService: NostrService) async -> Loaded? {
        let ask = Array(Set(ConfigService.shared.config.readRelays + MuteListStore.extraRelays))
        let lookup = await nostrService.lookupNewestReplaceable(kind: 10030, for: owner, alsoAsk: ask)
        guard let list = lookup.event else { return nil }
        let parsed = EmojiListParse.list(list.tags)
        let addresses = Array(parsed.setAddresses.prefix(maxSets))
        let events = await fetchSets(addresses, ask: ask, nostrService: nostrService)
        let sets = addresses.compactMap { address in
            events[address].map { EmojiListParse.set(address: address, tags: $0.tags) }
        }
        return Loaded(library: EmojiLibrary(owner: owner, single: parsed.single, sets: sets), list: list, events: events)
    }

    /// The newest signed 30030 for each address, asked of the account's
    /// relays plus `ask` and each author's outbox, `setsPerRequest` to a REQ.
    static func fetchSets(_ addresses: [String], ask: [String], nostrService: NostrService) async -> [String: NostrEvent] {
        let refs = addresses.compactMap { a in EmojiListParse.setRef(a).map { (a, $0) } }
        var out: [String: NostrEvent] = [:]
        for start in stride(from: 0, to: refs.count, by: setsPerRequest) {
            let chunk = Array(refs[start..<min(start + setsPerRequest, refs.count)])
            let authors = Array(Set(chunk.map(\.1.pubkey)))
            var relays = ConfigService.shared.config.readRelays
            for extra in ask + authors.flatMap({ nostrService.outboxRelays[$0] ?? [] }) where !relays.contains(extra) {
                relays.append(extra)
            }
            let filter: [String: Any] = ["kinds": [30030], "authors": authors, "#d": Array(Set(chunk.map(\.1.d)))]
            let found = await nostrService.fetchEvents(filter: filter, from: relays)
            for (address, ref) in chunk {
                let mine = found.filter { $0.kind == 30030 && $0.pubkey == ref.pubkey && Self.dTag($0.tags) == ref.d }
                if let newest = mine.max(by: { $0.created_at != $1.created_at ? $0.created_at < $1.created_at : $0.id > $1.id }) {
                    out[address] = newest
                }
            }
        }
        return out
    }

    private static func dTag(_ tags: [[String]]) -> String {
        tags.first { $0.count >= 2 && $0[0] == "d" }?[1] ?? ""
    }
}
