import Foundation
import Combine

/// One person's listings, for the Shop tab on their profile. Asks the
/// marketplace relays plus the seller's own write relays (NIP-65), since a
/// seller who lists from another client may only publish to their outbox.
@MainActor
final class SellerListingsLoader: ObservableObject {
    @Published private(set) var listings: [MarketListing] = []
    @Published private(set) var isLoading = false

    private var clients: [WebSocketClient] = []
    private var cancellables = Set<AnyCancellable>()
    private var book = MarketListingBook()
    private var timeout: Timer?
    private var loadedPubkey: String?

    func load(pubkey: String, force: Bool = false) {
        guard force || loadedPubkey != pubkey else { return }
        cancel()
        loadedPubkey = pubkey
        book.removeAll()
        listings = []
        isLoading = true

        let filter: [String: Any] = ["kinds": MarketListing.kinds, "authors": [pubkey], "limit": 100]
        let subId = "shop-\(UUID().uuidString.prefix(8))"
        var relays = MarketplaceFeedService.relayStrings
        for url in NostrService.shared.outboxRelays[pubkey] ?? [] where !relays.contains(url) {
            relays.append(url)
        }

        for url in relays.compactMap(URL.init(string:)) {
            let client = WebSocketClient()
            client.isTemporary = true
            clients.append(client)
            client.messageSubject
                .receive(on: DispatchQueue.main)
                .sink { [weak self] message in self?.handle(message, pubkey: pubkey) }
                .store(in: &cancellables)
            client.connect(url: url)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let req = ["REQ", subId, filter] as [Any]
                if let data = try? JSONSerialization.data(withJSONObject: req),
                   let text = String(data: data, encoding: .utf8) {
                    client.send(text: text)
                }
            }
        }

        timeout = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isLoading = false
                self?.cancel()
            }
        }
    }

    func cancel() {
        timeout?.invalidate()
        timeout = nil
        cancellables.removeAll()
        clients.forEach { $0.disconnect() }
        clients.removeAll()
    }

    private func handle(_ message: String, pubkey: String) {
        guard let data = message.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let type = json.first as? String else { return }
        if type == "EOSE" {
            // The first relay to finish is enough to stop the spinner; the
            // rest keep adding listings until the timeout.
            if !listings.isEmpty { isLoading = false }
            return
        }
        guard type == "EVENT", json.count >= 3,
              let event = json[2] as? [String: Any],
              let id = event["id"] as? String,
              event["pubkey"] as? String == pubkey,
              let content = event["content"] as? String,
              let createdAt = event["created_at"] as? Int64,
              let kind = event["kind"] as? Int,
              let tags = event["tags"] as? [[String]]
        else { return }

        // Newest event per address, as in the Marketplace feed: a sold
        // re-publish hides the item rather than being ignored.
        guard book.insert(id: id, pubkey: pubkey, kind: kind, content: content, createdAt: createdAt, tags: tags) else { return }
        listings = book.listings
        isLoading = false
    }
}
