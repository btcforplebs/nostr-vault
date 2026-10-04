import Foundation
import Combine

/// Marketplace feed.
///
/// Listings are NIP-15 products and auctions (kinds 30018/30020) and NIP-99
/// classifieds (30402), parsed by `MarketListing`. Like Recipes, sellers are
/// mostly strangers, so this talks to external relays directly and keeps its
/// results in memory only. Nothing is written to the owner's relay.
@MainActor
final class MarketplaceFeedService: ObservableObject {
    static let shared = MarketplaceFeedService()

    /// Listings newest-first, one per `kind:pubkey:d` address.
    @Published private(set) var listings: [MarketListing] = []
    @Published private(set) var isLoading = false
    /// Set when every relay failed or returned nothing.
    @Published private(set) var loadFailed = false
    /// Selected category chip, or nil for "All".
    @Published var selectedCategory: MarketCategory?
    /// Global by default, unlike Recipes: a marketplace is for finding sellers
    /// you do not follow yet, and almost nobody's follows sell anything, so a
    /// Following default would open on an empty screen.
    @Published private(set) var scope: RecipeScope = .global
    /// True when Following is selected and the owner follows nobody.
    @Published private(set) var followSetIsEmpty = false

    private var clients: [WebSocketClient] = []
    private var cancellables = Set<AnyCancellable>()
    private var book = MarketListingBook()
    private var loadTimeout: Timer?
    private var lastLoadedAt: Date?
    private var lastLoadedScope: RecipeScope?

    /// Results older than this are refetched when the feed is opened again.
    private static let staleAfter: TimeInterval = 10 * 60

    /// Where listings live. The MyNostrSpace marketplace's relay set, plus
    /// relay.primal.net: on 2026-10-04 nos.lol and relay.nostr.net timed out
    /// and primal returned a full page, so one slow relay never empties the
    /// grid. The owner's feed relays are not used; they rarely carry listings.
    static let relayStrings = [
        "wss://relay.damus.io",
        "wss://nos.lol",
        "wss://relay.snort.social",
        "wss://relay.nostr.net",
        "wss://nostr.wine",
        "wss://relay.primal.net",
    ]

    private init() {}

    /// Categories that have at least one listing, in `MarketCategory` order
    /// with Other last.
    var categories: [MarketCategory] {
        let present = Set(listings.map(\.category))
        return MarketCategory.allCases.filter { present.contains($0) }
    }

    /// Listings after the category chip is applied.
    var visibleListings: [MarketListing] {
        guard let selectedCategory else { return listings }
        return listings.filter { $0.category == selectedCategory }
    }

    /// Loads on first open, and again once the results have gone stale.
    /// Cheap to call from `onAppear`.
    func loadIfNeeded() {
        if isLoading { return }
        if let lastLoadedAt, lastLoadedScope == scope,
           Date().timeIntervalSince(lastLoadedAt) < Self.staleAfter, !listings.isEmpty { return }
        refresh()
    }

    /// Switches scope and reloads. The caller is responsible for showing the
    /// sensitive-content warning before selecting `.global`.
    func setScope(_ newScope: RecipeScope) {
        guard newScope != scope else { return }
        scope = newScope
        listings = []
        refresh()
    }

    func refresh() {
        disconnect()
        book.removeAll()
        loadFailed = false
        followSetIsEmpty = false
        isLoading = true

        var filter: [String: Any] = [
            "kinds": MarketListing.kinds,
            "limit": 200
        ]
        if scope == .following {
            let follows = FeedService.shared.followedPubkeys
            guard !follows.isEmpty else {
                // An `authors: []` REQ matches nothing and would look like a
                // dead feed. Say what is actually true instead.
                isLoading = false
                followSetIsEmpty = true
                return
            }
            filter["authors"] = follows
        }
        let subId = "market-\(UUID().uuidString.prefix(8))"
        let blocked = ConfigService.shared.activeAccountBlockedHexPubkeys

        for url in Self.relayStrings.compactMap(URL.init(string:)) {
            let client = WebSocketClient()
            client.isTemporary = true
            clients.append(client)

            client.messageSubject
                .receive(on: DispatchQueue.main)
                .sink { [weak self] message in
                    self?.handle(message: message, blocked: blocked)
                }
                .store(in: &cancellables)

            client.connect(url: url)

            // Same short delay before the REQ as the rest of the feed pipeline.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let req = ["REQ", subId, filter] as [Any]
                if let data = try? JSONSerialization.data(withJSONObject: req),
                   let text = String(data: data, encoding: .utf8) {
                    client.send(text: text)
                }
            }
        }

        // Stop waiting on relays that never answer, and keep whatever arrived.
        loadTimeout?.invalidate()
        loadTimeout = Timer.scheduledTimer(withTimeInterval: 12.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.finishLoading() }
        }
    }

    func disconnect() {
        loadTimeout?.invalidate()
        loadTimeout = nil
        cancellables.removeAll()
        clients.forEach { $0.disconnect() }
        clients.removeAll()
    }

    // MARK: - Private

    private func handle(message: String, blocked: Set<String>) {
        guard let data = message.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let type = json.first as? String else { return }

        if type == "EOSE" {
            // One relay reaching EOSE is enough to show results; the others
            // keep streaming in and republish as they land.
            publish()
            return
        }

        guard type == "EVENT", json.count >= 3,
              let event = json[2] as? [String: Any],
              let id = event["id"] as? String,
              let pubkey = event["pubkey"] as? String,
              let content = event["content"] as? String,
              let createdAt = event["created_at"] as? Int64,
              let kind = event["kind"] as? Int,
              let tags = event["tags"] as? [[String]],
              !blocked.contains(pubkey)
        else { return }

        // Addressable: the newest event at an address wins, including a
        // re-publish that marks the item sold.
        if book.insert(id: id, pubkey: pubkey, kind: kind, content: content, createdAt: createdAt, tags: tags) {
            publish()
        }
    }

    private func publish() {
        listings = book.listings
        if !listings.isEmpty {
            isLoading = false
            loadFailed = false
            lastLoadedAt = Date()
            lastLoadedScope = scope
        }
        if let selectedCategory, !categories.contains(selectedCategory) {
            self.selectedCategory = nil
        }
    }

    private func finishLoading() {
        isLoading = false
        loadFailed = listings.isEmpty
        if !listings.isEmpty {
            lastLoadedAt = Date()
            lastLoadedScope = scope
        }
        disconnect()
    }
}

// App-only parts of a listing: they need FeedNote and Bech32, which the
// MediaLogicTests package that tests the parser does not build.
extension MarketListing {
    /// The listing as a note, so Event Info (relays, raw JSON) can open on it.
    var note: FeedNote {
        FeedNote(id: id, pubkey: pubkey, content: content, createdAt: createdAt, tags: tags, kind: kind)
    }

    /// NIP-19 address of the listing (`naddr1…`), nil without a `d` tag.
    var naddr: String? {
        guard let dTag, let pubData = Bech32.hexToData(pubkey) else { return nil }
        var tlv = Data()
        tlv.append(Bech32.encodeTLV(type: 0, data: Data(dTag.utf8)))
        tlv.append(Bech32.encodeTLV(type: 2, data: pubData))
        let kindBytes = withUnsafeBytes(of: UInt32(kind).bigEndian) { Data($0) }
        tlv.append(Bech32.encodeTLV(type: 3, data: kindBytes))
        return Bech32.encode(hrp: "naddr", data: tlv)
    }

    /// Shopstr's page for the listing, as MyNostrSpace links it.
    var shopstrURL: URL? {
        guard let naddr else { return nil }
        return URL(string: "https://shopstr.store/listing/\(naddr)")
    }
}
