import Foundation

struct FeedProfile: Codable, Identifiable {
    let pubkey: String
    var name: String?
    var displayName: String?
    var pictureURL: URL?
    var nip05: String?
    var lud16: String?
    var about: String?
    var website: String?

    var id: String { pubkey }

    var bestName: String {
        if let d = displayName, !d.isEmpty { return d }
        if let n = name, !n.isEmpty { return n }
        return "npub…" + String(pubkey.suffix(6))
    }

    init(pubkey: String, name: String? = nil, displayName: String? = nil, pictureURL: URL? = nil, nip05: String? = nil, lud16: String? = nil, about: String? = nil, website: String? = nil) {
        self.pubkey = pubkey
        self.name = name
        self.displayName = displayName
        self.pictureURL = pictureURL
        self.nip05 = nip05
        self.lud16 = lud16
        self.about = about
        self.website = website
    }
}
