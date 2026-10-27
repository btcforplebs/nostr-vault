import Foundation
import Combine

/// The account's own custom emoji, read from Nostr and never written here:
/// the newest kind 10030 (NIP-51), its single `emoji` tags, and the 30030
/// sets its `a` tags add. Cached on disk so the picker has them at once;
/// refreshed at launch and whenever the picker opens. Saving to 10030 is a
/// later step. Android: `service/EmojiListRepository.kt`.
@MainActor
final class EmojiListService: ObservableObject {
    static let shared = EmojiListService()

    @Published private(set) var library = EmojiLibrary()

    /// Set by `FeedActions.make`, the one place every screen's actions come from.
    weak var nostrService: NostrService?

    private var refreshing: Task<Void, Never>?
    private var lastRefresh = Date.distantPast
    private static let refreshEvery: TimeInterval = 60
    /// Sets fetched per refresh; each is a lookup across the relays.
    private static let maxSets = 20

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

    /// Asks the relays again, at most once a minute. Shows nothing of another account's.
    func refresh() {
        guard let nostrService else { return }
        let owner = nostrService.activeHexPubkey
        guard !owner.isEmpty else { return }
        if !library.owner.isEmpty, library.owner != owner { library = EmojiLibrary(owner: owner) }
        guard refreshing == nil, Date().timeIntervalSince(lastRefresh) >= Self.refreshEvery else { return }
        lastRefresh = Date()
        refreshing = Task { [weak self] in
            let loaded = await Self.load(owner: owner, nostrService: nostrService)
            guard let self else { return }
            self.refreshing = nil
            guard let loaded, nostrService.activeHexPubkey == owner else { return }
            self.library = loaded
            if let url = self.cacheURL, let data = try? JSONEncoder().encode(loaded) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private static func load(owner: String, nostrService: NostrService) async -> EmojiLibrary? {
        let ask = Array(Set(ConfigService.shared.config.readRelays + MuteListStore.extraRelays))
        let lookup = await nostrService.lookupNewestReplaceable(kind: 10030, for: owner, alsoAsk: ask)
        guard let list = lookup.event else { return nil }
        let parsed = EmojiListParse.list(list.tags)
        let addresses = Array(parsed.setAddresses.prefix(maxSets))
        let sets = await withTaskGroup(of: (Int, EmojiLibrary.EmojiSet?).self) { group in
            for (index, address) in addresses.enumerated() {
                group.addTask {
                    guard let ref = EmojiListParse.setRef(address) else { return (index, nil) }
                    let found = await nostrService.lookupNewestReplaceable(kind: 30030, for: ref.pubkey, alsoAsk: ask, dTag: ref.d)
                    guard let event = found.event else { return (index, nil) }
                    return (index, EmojiListParse.set(address: address, tags: event.tags))
                }
            }
            var out: [(Int, EmojiLibrary.EmojiSet)] = []
            for await (index, set) in group { if let set { out.append((index, set)) } }
            return out.sorted { $0.0 < $1.0 }.map(\.1)
        }
        return EmojiLibrary(owner: owner, single: parsed.single, sets: sets)
    }
}
