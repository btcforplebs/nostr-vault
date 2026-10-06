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
        ConfigService.shared.$activeAccountHexPubkey
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
        let hex = accountHex
        guard !hex.isEmpty else { return false }
        let name = InterestList.normalize(hashtag)
        guard !name.isEmpty else { return false }

        // Optimistic: the button flips now.
        hashtags = list.setting(name, followed: followed).hashtags

        if !confirmed {
            let ok = await (fetch ?? startFetch()).value
            guard ok, accountHex == hex else {
                if accountHex == hex { hashtags = list.hashtags }
                return false
            }
        }

        let next = list.setting(name, followed: followed)
        guard next != list else {
            hashtags = list.hashtags
            return true
        }
        guard let event = await NostrService.shared.signEventAsync(kind: 10015, content: next.content, tags: next.tags),
              accountHex == hex else {
            if accountHex == hex { hashtags = list.hashtags }
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
            let result = await Self.fetchLatest(author: hex, relays: Self.queryRelays(for: hex))
            guard let self, !Task.isCancelled, self.accountHex == hex else { return false }
            self.fetch = nil
            guard let result else { return false }
            if let remote = result, remote.createdAt >= self.list.createdAt {
                self.accept(remote)
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

    /// Where an account's lists live: its own outbox first, then the relays
    /// this app reads and writes, including the local relay.
    private static func queryRelays(for hex: String) -> [URL] {
        let config = ConfigService.shared.config
        var urls: [String] = NostrService.shared.outboxRelays[hex] ?? []
        if RelayProcessManager.shared.isRunning, !RelayProcessManager.shared.isBooting {
            urls.append(config.nostrURL)
        }
        urls += config.activeFeedRelays + config.activeBlastrRelays
        if urls.isEmpty { urls = ["wss://relay.primal.net", "wss://nos.lol"] }
        var seen = Set<String>()
        return urls.filter { seen.insert($0).inserted }.compactMap(URL.init(string:))
    }

    /// The newest kind 10015 by `author`. Outer nil: no relay answered.
    /// Inner nil: relays answered and have none.
    private static func fetchLatest(author: String, relays: [URL]) async -> InterestList?? {
        guard !relays.isEmpty else { return nil }
        return await withCheckedContinuation { continuation in
            let query = OneShotQuery(relays: relays, author: author) { continuation.resume(returning: $0) }
            query.start()
        }
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

/// One REQ for an author's kind 10015 across several relays. Finishes when
/// every relay sent EOSE, or after a timeout with whatever arrived.
@MainActor
private final class OneShotQuery {
    private let relays: [URL]
    private let author: String
    private var completion: ((InterestList??) -> Void)?
    private var clients: [WebSocketClient] = []
    private var cancellables = Set<AnyCancellable>()
    private var answered = 0
    private var newest: InterestList?
    private var retainSelf: OneShotQuery?

    init(relays: [URL], author: String, completion: @escaping (InterestList??) -> Void) {
        self.relays = relays
        self.author = author
        self.completion = completion
    }

    func start() {
        retainSelf = self
        let subId = "interests-\(UUID().uuidString.prefix(8))"
        let filter: [String: Any] = ["kinds": [10015], "authors": [author], "limit": 1]
        guard let data = try? JSONSerialization.data(withJSONObject: ["REQ", subId, filter] as [Any]),
              let req = String(data: data, encoding: .utf8) else {
            finish()
            return
        }
        for url in relays {
            let client = WebSocketClient()
            client.isTemporary = true
            clients.append(client)
            var sent = false
            client.$connectionState
                .receive(on: DispatchQueue.main)
                .sink { [weak client] state in
                    guard state == .connected, !sent, let client else { return }
                    sent = true
                    client.send(text: req)
                }
                .store(in: &cancellables)
            client.messageSubject
                .receive(on: DispatchQueue.main)
                .sink { [weak self] message in self?.handle(message, subId: subId) }
                .store(in: &cancellables)
            client.connect(url: url)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.finish() }
    }

    private func handle(_ message: String, subId: String) {
        guard let data = message.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              json.count >= 2, let type = json[0] as? String, json[1] as? String == subId else { return }
        if type == "EOSE" {
            answered += 1
            if answered >= relays.count { finish() }
            return
        }
        guard type == "EVENT", json.count >= 3,
              let eventData = try? JSONSerialization.data(withJSONObject: json[2]),
              let event = try? JSONDecoder().decode(NostrEvent.self, from: eventData),
              event.kind == 10015, event.pubkey == author else { return }
        if event.created_at > (newest?.createdAt ?? -1) {
            newest = InterestList(tags: event.tags, content: event.content, createdAt: event.created_at)
        }
    }

    private func finish() {
        guard let completion else { return }
        self.completion = nil
        clients.forEach { $0.disconnect() }
        clients = []
        cancellables.removeAll()
        if newest != nil || answered > 0 {
            completion(.some(newest))
        } else {
            completion(nil)
        }
        retainSelf = nil
    }
}
