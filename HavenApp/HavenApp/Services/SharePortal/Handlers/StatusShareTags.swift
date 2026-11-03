import Foundation

/// NIP-38 user status (kind 30315) for a shared music/video link (§6.4).
enum StatusShareTags {
    static let kind = 30315
    /// Expiry choices on the card, in seconds; the first is not the default.
    static let durations: [(label: String, seconds: Int)] = [("30 min", 1800), ("1 hour", 3600), ("4 hours", 14_400)]
    static let defaultSeconds = 3600

    static func tags(text: String, url: String?, expiration: Int) -> [[String]] {
        var tags: [[String]] = [["d", "music"]]
        if let url, !url.isEmpty { tags.append(["r", url]) }
        tags.append(["expiration", String(expiration)])
        tags.append(["alt", "Status: \(text.trimmingCharacters(in: .whitespacesAndNewlines))"])
        return tags
    }
}
