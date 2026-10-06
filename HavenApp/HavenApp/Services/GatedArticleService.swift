import Foundation

/// Unlocks gated ("zap N sats to unlock") articles — see `GatedArticle`.
///
/// The key server is the only judge of whether a zap counted, so this never
/// decides "paid" itself: it asks, and a 402 means not yet.
@MainActor
final class GatedArticleService {
    static let shared = GatedArticleService()
    private init() {}

    enum UnlockError: LocalizedError {
        case notSignedIn
        case signFailed
        case notPaid
        case noLightningAddress
        case server(Int, String)
        case undecryptable

        var errorDescription: String? {
            switch self {
            case .notSignedIn: return "Sign in to unlock this article."
            case .signFailed: return "Your signer didn't sign the unlock request."
            case .notPaid: return "The author hasn't seen your zap yet."
            case .noLightningAddress: return "The author has no lightning address to zap."
            case .server(let code, let text): return "The key server answered \(code): \(text)"
            case .undecryptable: return "The key didn't open this article."
            }
        }
    }

    /// Keys already fetched, by reader pubkey and article coordinate. A key
    /// belongs to the article address, not one version of it, so an edit keeps
    /// it; a key that stops working is dropped and asked for again.
    private let defaultsKey = "gatedArticle.keys.v1"

    private func cacheKey(reader: String, coordinate: String) -> String { "\(reader)|\(coordinate)" }

    private func cachedKey(reader: String, coordinate: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String])?[cacheKey(reader: reader, coordinate: coordinate)]
    }

    private func storeKey(_ key: String?, reader: String, coordinate: String) {
        var all = (UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String]) ?? [:]
        all[cacheKey(reader: reader, coordinate: coordinate)] = key
        UserDefaults.standard.set(all, forKey: defaultsKey)
    }

    /// The article body, if this reader can already read it: a stored key, or
    /// the server says they paid (on Fanfares, or from another client).
    /// Throws `.notPaid` when they haven't.
    func open(note: FeedNote, gated: GatedArticle) async throws -> String {
        let reader = NostrService.shared.activeHexPubkey
        guard !reader.isEmpty else { throw UnlockError.notSignedIn }
        guard let coordinate = NIP10Thread.coordinate(kind: note.kind, pubkey: note.pubkey, tags: note.tags) else {
            throw UnlockError.undecryptable
        }
        if let key = cachedKey(reader: reader, coordinate: coordinate) {
            if let body = gated.decrypt(keyHex: key) { return body }
            storeKey(nil, reader: reader, coordinate: coordinate)
        }
        let key = try await requestKey(note: note, gated: gated)
        guard let body = gated.decrypt(keyHex: key) else { throw UnlockError.undecryptable }
        storeKey(key, reader: reader, coordinate: coordinate)
        return body
    }

    /// Articles this reader has zapped to unlock, by coordinate, so a receipt
    /// that is slow to arrive never turns the button back into "pay".
    private let paidKey = "gatedArticle.paid.v1"

    func hasPaid(note: FeedNote) -> Bool {
        guard let coordinate = NIP10Thread.coordinate(kind: note.kind, pubkey: note.pubkey, tags: note.tags) else { return false }
        let reader = NostrService.shared.activeHexPubkey
        return (UserDefaults.standard.stringArray(forKey: paidKey) ?? []).contains(cacheKey(reader: reader, coordinate: coordinate))
    }

    /// Zaps every share of the price. Recorded as paid once the first share
    /// has gone out, because from then on money has moved.
    func pay(note: FeedNote, gated: GatedArticle) async throws {
        let coordinate = NIP10Thread.coordinate(kind: note.kind, pubkey: note.pubkey, tags: note.tags)
        for share in gated.shares {
            guard let lud = await lightningAddress(for: share.pubkey) else { throw UnlockError.noLightningAddress }
            try await ZapService.shared.zapNote(noteId: note.id, notePubkey: share.pubkey, lud16: lud,
                                                amountSats: share.sats, message: "Unlocked with Nostr Vault",
                                                addressTag: coordinate, extraReceiptRelays: gated.receiptRelays)
            if let coordinate {
                let key = cacheKey(reader: NostrService.shared.activeHexPubkey, coordinate: coordinate)
                var paid = UserDefaults.standard.stringArray(forKey: paidKey) ?? []
                if !paid.contains(key) { paid.append(key); UserDefaults.standard.set(paid, forKey: paidKey) }
            }
        }
        FeedService.shared.zappedEventIds[note.id] = gated.priceSats
        FeedService.shared.saveInteractionState()
    }

    /// Asks for the key until the server has seen the receipts. The receipt
    /// is published by the author's lightning provider, so it lands seconds
    /// after the payment, not with it. Never pays.
    func waitForKey(note: FeedNote, gated: GatedArticle) async throws -> String {
        var lastError: Error = UnlockError.notPaid
        for delay in [2, 3, 4, 5, 6, 8, 10] {
            try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            do {
                return try await open(note: note, gated: gated)
            } catch UnlockError.notPaid {
                lastError = UnlockError.notPaid
            } catch {
                lastError = error
                if case UnlockError.server(let code, _) = error, code < 500 { break }
            }
        }
        throw lastError
    }

    private func requestKey(note: FeedNote, gated: GatedArticle) async throws -> String {
        let meta = note.longFormMetadata
        let relay = gated.shares.first(where: { $0.pubkey == note.pubkey })?.relay ?? gated.receiptRelays.first
        guard let identifier = meta.identifier,
              let tlv = GatedArticle.naddrTLV(identifier: identifier, relay: relay, pubkey: note.pubkey, kind: note.kind),
              let naddr = Bech32.encode(hrp: "naddr", data: tlv) else { throw UnlockError.undecryptable }
        guard let auth = await NostrService.shared.signEventAsync(kind: 27235, content: naddr, tags: gated.httpAuthTags),
              let json = try? JSONEncoder().encode(auth) else { throw UnlockError.signFailed }

        var request = URLRequest(url: gated.requestURL, timeoutInterval: 20)
        request.setValue("Nostr \(json.base64EncodedString())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch status {
        case 200: return text
        case 402: throw UnlockError.notPaid
        default:
            RelayProcessManager.shared.addLog("Gated article: key request \(status): \(text.prefix(200))", level: "ERROR")
            throw UnlockError.server(status, String(text.prefix(120)))
        }
    }

    private func lightningAddress(for pubkey: String) async -> String? {
        func lookup() -> String? {
            guard let profile = NostrService.shared.profiles[pubkey] else { return nil }
            if let lud06 = profile.lud06, !lud06.isEmpty { return "lnurl:" + lud06 }
            if let lud16 = profile.lud16, !lud16.isEmpty { return lud16 }
            return nil
        }
        if let found = lookup() { return found }
        NostrService.shared.fetchMissingProfiles(for: [pubkey])
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if let found = lookup() { return found }
        }
        return nil
    }
}

extension FeedNote {
    /// The article's zap-to-unlock terms, or nil for an ordinary article.
    var gatedArticle: GatedArticle? { GatedArticle(kind: kind, pubkey: pubkey, tags: tags) }
}
