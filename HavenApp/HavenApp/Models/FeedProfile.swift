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
}
