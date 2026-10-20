import Foundation

/// Opens gated ("zap N sats to unlock") articles — see `GatedArticle`.
///
/// The app never pays to unlock on iPhone or Mac: that is buying digital
/// content (App Store 3.1.1). A Fanfares article is bought on Fanfares, and
/// the app then asks Fanfares' key server for the key; the server is the only
/// judge of whether a zap counted, so a 402 means not yet. Any other gated
/// article only opens with a key an earlier version stored.
@MainActor
final class GatedArticleService {
    static let shared = GatedArticleService()
    private init() {}

    enum UnlockError: LocalizedError {
        case notSignedIn
        case signFailed
        case notPaid
        case server(Int, String)
        case undecryptable

        var errorDescription: String? {
            switch self {
            case .notSignedIn: return "Sign in to unlock this article."
            case .signFailed: return "Your signer didn't sign the unlock request."
            case .notPaid: return "Fanfares hasn't seen a payment for this article from you yet."
            case .server(let code, let text): return "The key server answered \(code): \(text)"
            case .undecryptable: return "The key didn't open this article."
            }
        }
    }

    /// Keys already fetched, by reader pubkey and article coordinate. A key
    /// belongs to the article address, not one version of it, so an edit keeps
    /// it; a key that stops working is dropped (and, on Fanfares, asked for again).
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

    /// The article body, if this reader's stored key opens it; nil keeps it
    /// locked. Never asks the network or the signer.
    func unlockedBody(note: FeedNote, gated: GatedArticle) -> String? {
        let reader = NostrService.shared.activeHexPubkey
        guard !reader.isEmpty,
              let coordinate = NIP10Thread.coordinate(kind: note.kind, pubkey: note.pubkey, tags: note.tags),
              let key = cachedKey(reader: reader, coordinate: coordinate) else { return nil }
        return gated.decrypt(keyHex: key)
    }

    /// The article body, if this reader can already read it: a stored key, or
    /// (Fanfares only) the key server says they paid. Throws `.notPaid` when
    /// they haven't, and for every other gated article without a stored key.
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
        guard gated.isFanfares else { throw UnlockError.notPaid }
        let key = try await requestKey(note: note, gated: gated)
        guard let body = gated.decrypt(keyHex: key) else { throw UnlockError.undecryptable }
        storeKey(key, reader: reader, coordinate: coordinate)
        return body
    }

    /// Whether opening a gated article may ask the signer on its own. A local
    /// key signs silently; a remote signer would prompt on every view.
    var canCheckSilently: Bool {
        ConfigService.shared.config.activeSigningMode() == "local"
    }

    /// The article's naddr, byte-identical to the one Fanfares' own site uses.
    func naddr(note: FeedNote, gated: GatedArticle) -> String? {
        let relay = gated.shares.first(where: { $0.pubkey == note.pubkey })?.relay ?? gated.receiptRelays.first
        guard let identifier = note.longFormMetadata.identifier,
              let tlv = GatedArticle.naddrTLV(identifier: identifier, relay: relay, pubkey: note.pubkey, kind: note.kind)
        else { return nil }
        return Bech32.encode(hrp: "naddr", data: tlv)
    }

    /// Where to read or buy a Fanfares article; nil for any other.
    func fanfaresURL(note: FeedNote, gated: GatedArticle) -> URL? {
        guard gated.isFanfares else { return nil }
        if let naddr = naddr(note: note, gated: gated), let url = GatedArticle.fanfaresURL(naddr: naddr) { return url }
        return GatedArticleTeaser.unlockURL(note.content)
    }

    private func requestKey(note: FeedNote, gated: GatedArticle) async throws -> String {
        guard let naddr = naddr(note: note, gated: gated) else { throw UnlockError.undecryptable }
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
}

extension FeedNote {
    /// The article's zap-to-unlock terms, or nil for an ordinary article.
    var gatedArticle: GatedArticle? { GatedArticle(kind: kind, pubkey: pubkey, tags: tags) }
}
