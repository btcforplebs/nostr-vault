import Foundation

/// The address the app writes events it pulled from relays to (FeedService's
/// and NetworkSyncService's outbox injection clients): this vault's relay
/// with `?pulled=1`. The relay stores those and never blasts them back out
/// (haven-go `isPulledConn`, Logen's pick 2026-11-12: re-sending what it just
/// fetched was the .99 Mac's blast storm). Events the app posts go to the
/// plain address and are blasted as before.
enum PulledInjection {
    static let queryItem = URLQueryItem(name: "pulled", value: "1")

    static func url(_ relay: String) -> URL? {
        guard var parts = URLComponents(string: relay) else { return nil }
        var items = (parts.queryItems ?? []).filter { $0.name != queryItem.name }
        items.append(queryItem)
        parts.queryItems = items
        return parts.url
    }
}
