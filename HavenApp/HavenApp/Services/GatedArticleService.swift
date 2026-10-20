import Foundation

/// Opens gated articles this reader already unlocked — see `GatedArticle`.
///
/// The app no longer pays for or requests article keys. Keys fetched by
/// earlier versions stay stored, so an article unlocked then still opens.
@MainActor
final class GatedArticleService {
    static let shared = GatedArticleService()
    private init() {}

    /// Keys already fetched, by reader pubkey and article coordinate. A key
    /// belongs to the article address, not one version of it, so an edit keeps
    /// it.
    private let defaultsKey = "gatedArticle.keys.v1"

    private func cachedKey(reader: String, coordinate: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String])?["\(reader)|\(coordinate)"]
    }

    /// The article body, if this reader's stored key opens it; nil keeps it
    /// locked.
    func unlockedBody(note: FeedNote, gated: GatedArticle) -> String? {
        let reader = NostrService.shared.activeHexPubkey
        guard !reader.isEmpty,
              let coordinate = NIP10Thread.coordinate(kind: note.kind, pubkey: note.pubkey, tags: note.tags),
              let key = cachedKey(reader: reader, coordinate: coordinate) else { return nil }
        return gated.decrypt(keyHex: key)
    }
}

extension FeedNote {
    /// The article's lock, or nil for an ordinary article.
    var gatedArticle: GatedArticle? { GatedArticle(kind: kind, pubkey: pubkey, tags: tags) }
}
