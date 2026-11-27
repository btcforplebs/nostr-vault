import Foundation

/// What a Vault note row (Notes, Likes, Zaps) draws from its event, worked
/// out once per event id. A row's body runs on every store change, and each
/// run decoded a repost's JSON and ran the media regex three times (Vault
/// review 2026-11-27 #2). An event's id
/// is the hash of its content and tags, so the result never goes stale.
@MainActor
enum NoteRowParse {
    struct Parsed {
        let reposted: NostrEvent?
        let mediaURLs: [URL]
        let linkURLs: [URL]
    }

    private static var cache: [String: Parsed] = [:]
    /// Rows on screen are a few dozen; the cap only bounds a long session.
    static let limit = 2000

    static func parsed(_ event: NostrEvent) -> Parsed {
        if let hit = cache[event.id] { return hit }
        let parsed = Parsed(reposted: reposted(event), mediaURLs: event.mediaURLs, linkURLs: event.linkURLs)
        if cache.count >= limit { cache.removeAll(keepingCapacity: true) }
        cache[event.id] = parsed
        return parsed
    }

    /// For a kind 6 repost, the original note embedded as JSON.
    static func reposted(_ event: NostrEvent) -> NostrEvent? {
        guard event.kind == 6, let data = event.content.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(NostrEvent.self, from: data)
    }

    static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}
