import Foundation

/// "Open in …": where a piece of Nostr content lives on the web, so it can be
/// opened in the system browser and checked off the device. One site per kind
/// of content, the same on every platform:
///
/// - recipes → zap.cooking (`/recipe/<naddr>`)
/// - live streams → zap.stream (`/<naddr>`)
/// - long-form articles → YakiHonne (`/article/<naddr>`). Habla was the other
///   choice; habla.news answered 404 on its own home page on 2026-10-20.
/// - profiles and trust → Brainstorm (`/p/<nprofile>`), whose page shows the
///   person's web-of-trust scores.
///
/// Routes were read from each site's own source or bundle on 2026-10-20.
/// Links carry `naddr` / `nprofile`, never hex, so any NIP-19 reader can use
/// them.
enum NostrWebLink: Equatable {
    case recipe(URL)
    case liveStream(URL)
    case article(URL)
    case profile(URL)

    var url: URL {
        switch self {
        case .recipe(let url), .liveStream(let url), .article(let url), .profile(let url): return url
        }
    }

    /// The site's name as its menu item says it: "Open in zap.cooking".
    var siteName: String {
        switch self {
        case .recipe: return "zap.cooking"
        case .liveStream: return "zap.stream"
        case .article: return "YakiHonne"
        case .profile: return "Brainstorm"
        }
    }

    static let longFormKind = 30023
    static let liveStreamKind = 30311

    /// A long-form post: a recipe when its tags say so, else an article.
    /// Nil for any other kind or without a `d` tag, since an `naddr` needs one.
    static func longForm(kind: Int, pubkey: String, tags: [[String]]) -> NostrWebLink? {
        guard kind == longFormKind, let dTag = dTag(in: tags),
              let naddr = naddr(kind: kind, pubkey: pubkey, identifier: dTag) else { return nil }
        if VaultNoteScope.isRecipe(tags: tags) {
            return URL(string: "https://zap.cooking/recipe/\(naddr)").map(NostrWebLink.recipe)
        }
        return URL(string: "https://yakihonne.com/article/\(naddr)").map(NostrWebLink.article)
    }

    /// A NIP-53 stream, addressed by who signed it (not the host), with the
    /// stream's own relays as hints.
    static func liveStream(authorPubkey: String, identifier: String, relays: [String] = []) -> NostrWebLink? {
        guard let naddr = naddr(kind: liveStreamKind, pubkey: authorPubkey, identifier: identifier,
                                relays: relays) else { return nil }
        return URL(string: "https://zap.stream/\(naddr)").map(NostrWebLink.liveStream)
    }

    static func profile(pubkey: String) -> NostrWebLink? {
        guard let nprofile = nprofile(pubkey: pubkey) else { return nil }
        return URL(string: "https://brainstorm.world/p/\(nprofile)").map(NostrWebLink.profile)
    }

    // MARK: - NIP-19

    /// At most this many relay hints go in a link, so it stays short enough
    /// to paste.
    static let maxRelayHints = 2

    static func naddr(kind: Int, pubkey: String, identifier: String, relays: [String] = []) -> String? {
        guard let pubData = Bech32.hexToData(pubkey), pubData.count == 32,
              let kind32 = UInt32(exactly: kind),
              let dEntry = Bech32.tlvEntry(type: 0, data: Data(identifier.utf8)),
              let authorEntry = Bech32.tlvEntry(type: 2, data: pubData),
              let kindEntry = Bech32.tlvEntry(type: 3, data: withUnsafeBytes(of: kind32.bigEndian) { Data($0) })
        else { return nil }
        return Bech32.encode(hrp: "naddr", data: dEntry + relayEntries(relays) + authorEntry + kindEntry)
    }

    static func nprofile(pubkey: String, relays: [String] = []) -> String? {
        guard let pubData = Bech32.hexToData(pubkey), pubData.count == 32,
              let keyEntry = Bech32.tlvEntry(type: 0, data: pubData) else { return nil }
        return Bech32.encode(hrp: "nprofile", data: keyEntry + relayEntries(relays))
    }

    private static func relayEntries(_ relays: [String]) -> Data {
        relays.filter { $0.hasPrefix("wss://") || $0.hasPrefix("ws://") }
            .prefix(maxRelayHints)
            .reduce(into: Data()) { $0.append(Bech32.encodeTLV(type: 1, data: Data($1.utf8))) }
    }

    private static func dTag(in tags: [[String]]) -> String? {
        tags.first { $0.count >= 2 && $0[0] == "d" }?[1]
    }
}
