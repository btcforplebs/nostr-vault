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

    /// Shares this reader has started paying, as "reader|coordinate|recipient".
    /// A share is recorded BEFORE its zap goes out: a wallet that times out
    /// may still have paid, and a share that might have been paid must never
    /// be offered again.
    private let paidKey = "gatedArticle.paidShares.v1"

    private func paidShares() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: paidKey) ?? [])
    }

    private func shareKey(_ note: FeedNote, _ share: GatedArticle.Share) -> String? {
        guard let coordinate = NIP10Thread.coordinate(kind: note.kind, pubkey: note.pubkey, tags: note.tags) else { return nil }
        return cacheKey(reader: NostrService.shared.activeHexPubkey, coordinate: coordinate) + "|" + share.pubkey
    }

    /// Shares not yet paid (or attempted). Empty means everything that can be
    /// paid has been, and all that's left is waiting for the key.
    func unpaidShares(note: FeedNote, gated: GatedArticle) -> [GatedArticle.Share] {
        let paid = paidShares()
        return gated.shares.filter { share in shareKey(note, share).map { !paid.contains($0) } ?? true }
    }

    /// True once any money may have moved for this article.
    func hasPaid(note: FeedNote, gated: GatedArticle) -> Bool {
        unpaidShares(note: note, gated: gated).count < gated.shares.count
    }

    #if !os(iOS)
    /// Zaps every share not already paid. Every recipient's lightning address
    /// is found first, so a missing one fails before any money moves. Not on
    /// iOS: paying to unlock is buying digital content (App Store 3.1.1).
    func pay(note: FeedNote, gated: GatedArticle) async throws {
        let coordinate = NIP10Thread.coordinate(kind: note.kind, pubkey: note.pubkey, tags: note.tags)
        let due = unpaidShares(note: note, gated: gated)
        var targets: [(GatedArticle.Share, String)] = []
        for share in due {
            guard let lud = await lightningAddress(for: share.pubkey) else { throw UnlockError.noLightningAddress }
            targets.append((share, lud))
        }
        for (share, lud) in targets {
            let key = shareKey(note, share)
            if let key { record(key, paid: true) }
            do {
                try await ZapService.shared.zapNote(noteId: note.id, notePubkey: share.pubkey, lud16: lud,
                                                    amountSats: share.sats, message: "Unlocked with Nostr Vault",
                                                    addressTag: coordinate, extraReceiptRelays: gated.receiptRelays)
            } catch {
                // Failures before the wallet was asked to pay leave no money
                // moved, so the share can be offered again. A payment error
                // (a wallet timeout included) may still have paid: keep it.
                if let key, Self.failedBeforePaying(error) { record(key, paid: false) }
                throw error
            }
        }
        FeedService.shared.zappedEventIds[note.id] = gated.priceSats
        FeedService.shared.saveInteractionState()
    }
    #endif

    private func record(_ key: String, paid: Bool) {
        var all = paidShares()
        if paid { all.insert(key) } else { all.remove(key) }
        UserDefaults.standard.set(Array(all), forKey: paidKey)
    }

    private static func failedBeforePaying(_ error: Error) -> Bool {
        switch error as? ZapService.ZapError {
        case .lnurlResolutionFailed, .invoiceFetchFailed, .signFailed: return true
        case .paymentFailed(let message):
            // No wallet connected: nothing was sent.
            return message == NWCService.NWCError.invalidURI.errorDescription
        case nil: return false
        }
    }

    /// Whether opening a gated article may ask the signer on its own. A local
    /// key signs silently; a remote signer would prompt on every view.
    var canCheckSilently: Bool {
        ConfigService.shared.config.activeSigningMode() == "local"
    }

    /// Asks for the key until the server has seen the receipts. The receipt
    /// is published by the author's lightning provider, so it lands seconds
    /// after the payment, not with it — and Fanfares' server took about two
    /// minutes to see a paid receipt on the first real unlock (2026-10-06),
    /// answering each check in ~4 s. So keep asking for about three minutes.
    /// Never pays.
    func waitForKey(note: FeedNote, gated: GatedArticle) async throws -> String {
        var lastError: Error = UnlockError.notPaid
        for delay in [2, 3, 5, 5, 8, 8, 10, 10, 10, 15, 15, 15, 15, 15] {
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
