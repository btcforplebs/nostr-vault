import Foundation
import Combine

/// Loads, caches and publishes the active account's interest list.
@MainActor
final class InterestListService: ObservableObject {
    static let shared = InterestListService()

    /// Followed hashtags for the active account.
    @Published private(set) var hashtags: [String] = []

    private var list = InterestList()
    private var accountHex = ""
    /// True once a relay answered for this account, so a publish can't
    /// overwrite a list we never saw.
    private var confirmed = false
    private var fetch: Task<Bool, Never>?
    private var cancellables = Set<AnyCancellable>()

    private init() {
        // The cached list right away: the feed's first load asks whether
        // this account follows any topics before the publisher's next turn.
        switchAccount(to: ConfigService.shared.activeAccountHexPubkey)
        ConfigService.shared.$activeAccountHexPubkey
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] hex in self?.switchAccount(to: hex) }
            .store(in: &cancellables)
    }

    func isFollowing(_ hashtag: String) -> Bool {
        hashtags.contains(InterestList.normalize(hashtag))
    }

    /// Fetches the latest list from relays once per account.
    func refreshIfNeeded() {
        guard !accountHex.isEmpty, !confirmed, fetch == nil else { return }
        _ = startFetch()
    }

    /// Follows or unfollows a hashtag and publishes the new list. Shows the
    /// change at once; puts it back if the relays' copy can't be read or the
    /// event can't be signed. Returns false when nothing was published.
    @discardableResult
    func setFollowing(_ hashtag: String, _ followed: Bool) async -> Bool {
        await setFollowing([hashtag], followed)
    }

    /// `setFollowing` for several hashtags at once, as one published list.
    @discardableResult
    func setFollowing(_ hashtags: [String], _ followed: Bool) async -> Bool {
        let hex = accountHex
        guard !hex.isEmpty else { return false }
        let names = hashtags.map(InterestList.normalize).filter { !$0.isEmpty }
        guard !names.isEmpty else { return false }
        func applied(to base: InterestList) -> InterestList {
            names.reduce(base) { $0.setting($1, followed: followed) }
        }

        // Optimistic: the button flips now.
        self.hashtags = applied(to: list).hashtags

        // Every save starts from the newest list on the relays, fetched now,
        // not the copy read at launch (Logen 2026-10-31). A key setup just
        // made is asked about too (InterestList.saveBase).
        let ok = await (fetch ?? startFetch()).value
        guard ok, accountHex == hex else {
            if accountHex == hex { self.hashtags = list.hashtags }
            return false
        }

        let next = applied(to: list)
        guard next != list else {
            self.hashtags = list.hashtags
            return true
        }
        let notBefore = list.createdAt > 0 ? ListMerge.signedAt(now: Int64(Date().timeIntervalSince1970), base: list.createdAt) : nil
        guard let event = await NostrService.shared.signEventAsync(kind: 10015, content: next.content, tags: next.tags,
                                                                   notBefore: notBefore),
              accountHex == hex, event.pubkey == hex else {
            if accountHex == hex { self.hashtags = list.hashtags }
            return false
        }
        var published = next
        published.createdAt = max(event.created_at, list.createdAt + 1)
        accept(published)
        NostrService.shared.postEvent(event)
        return true
    }

    // MARK: - Private

    private func switchAccount(to hex: String) {
        fetch?.cancel()
        fetch = nil
        accountHex = hex
        confirmed = false
        list = Self.loadCached(for: hex) ?? InterestList()
        hashtags = list.hashtags
        refreshIfNeeded()
    }

    private func startFetch() -> Task<Bool, Never> {
        let hex = accountHex
        let task = Task { [weak self] () -> Bool in
            let lookup = await NostrService.shared.lookupNewestReplaceable(
                kind: 10015, for: hex, alsoAsk: Self.queryRelays(for: hex), skipAhead: true)
            guard let self, !Task.isCancelled, self.accountHex == hex else { return false }
            self.fetch = nil
            let found = ReplaceableLookup(
                event: lookup.event.map { InterestList(tags: $0.tags, content: $0.content, createdAt: $0.created_at) },
                asked: lookup.asked, answered: lookup.answered, answeredBy: lookup.answeredBy,
                from: lookup.from, ahead: lookup.ahead)
            switch InterestList.saveBase(found, held: self.list, own: NostrService.ownListRelays(for: hex),
                                         fresh: FreshAccountKeys.isFresh(hex)) {
            case .list(let newest):
                if newest.createdAt >= self.list.createdAt { self.accept(newest) }
            case .none:
                // The relays agree there is no list: a save starts from an
                // empty one, not from what this phone cached.
                self.accept(InterestList())
            case .unknown, .noRelayList:
                return false
            }
            self.confirmed = true
            return true
        }
        fetch = task
        return task
    }

    private func accept(_ newList: InterestList) {
        list = newList
        hashtags = newList.hashtags
        Self.saveCached(newList, for: accountHex)
    }

    /// Where else to ask besides the account's own write relays (which the
    /// lookup always asks): the relays this app reads and writes. Not the
    /// local relay: it holds whatever copy this device last saw, which may
    /// be older than the network's.
    private static func queryRelays(for hex: String) -> [String] {
        let config = ConfigService.shared.config
        var seen = Set<String>()
        return (config.activeFeedRelays + config.activeBlastrRelays).filter { seen.insert($0).inserted }
    }

    // MARK: Cache

    private static func cacheKey(_ hex: String) -> String { "interestList.\(hex)" }

    private static func loadCached(for hex: String) -> InterestList? {
        guard !hex.isEmpty, let data = UserDefaults.standard.data(forKey: cacheKey(hex)) else { return nil }
        return try? JSONDecoder().decode(InterestList.self, from: data)
    }

    private static func saveCached(_ list: InterestList, for hex: String) {
        guard !hex.isEmpty, let data = try? JSONEncoder().encode(list) else { return }
        UserDefaults.standard.set(data, forKey: cacheKey(hex))
    }
}
