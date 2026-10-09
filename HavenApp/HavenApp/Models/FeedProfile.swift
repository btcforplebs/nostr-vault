import Foundation

struct FeedProfile: Codable, Identifiable, Equatable {
    let pubkey: String
    var name: String?
    var displayName: String?
    var pictureURL: URL?
    /// The wide header image (kind-0 `banner`).
    var bannerURL: URL?
    var nip05: String?
    var lud16: String?
    var lud06: String? // Raw bech32-encoded LNURL (LUD-06 fallback)
    var about: String?
    var website: String?
    /// `created_at` of the kind 0 these fields came from. Relays hold different
    /// versions of a profile and answer in any order, so an older one arriving
    /// last must not replace a newer one. Nil for profiles cached before this.
    var metadataCreatedAt: Int64?

    var id: String { pubkey }

    var bestName: String {
        if let d = displayName, !d.isEmpty { return d }
        if let n = name, !n.isEmpty { return n }
        return "npub…" + String(pubkey.suffix(6))
    }

    init(pubkey: String, name: String? = nil, displayName: String? = nil, pictureURL: URL? = nil, nip05: String? = nil, lud16: String? = nil, lud06: String? = nil, about: String? = nil, website: String? = nil) {
        self.pubkey = pubkey
        self.name = name
        self.displayName = displayName
        self.pictureURL = pictureURL
        self.nip05 = nip05
        self.lud16 = lud16
        self.lud06 = lud06
        self.about = about
        self.website = website
    }
}
