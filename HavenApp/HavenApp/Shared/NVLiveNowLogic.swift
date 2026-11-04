import Foundation

// MARK: - Live now (Home Screen widget)
//
// The Home Screen twin of Your space's Live now panel (`LiveNow`): people you
// follow who are on air, picture + name + stream title, a tap opens the
// stream. The app cannot hand over "who is live" ahead of time -- a stream
// starts and ends while the app is closed -- so the app hands over who you
// follow, and the widget asks the live relays itself inside its timeline
// budget (`LiveNowWidget`). The picking rules are `LiveNow.pick`, the same
// code the panel runs.
//
// Pure Foundation so MediaLogicTests covers it.

/// What the app hands the widget: who to look for, where, and who never to show.
struct NVLiveHandoff: Codable, Equatable {
    var generatedAt: Date
    /// The active account's follows (hex).
    var follows: [String]
    /// False until the follow list has loaded once, so "follows nobody" is not
    /// said about a list that simply has not arrived yet.
    var followListIsKnown: Bool
    var blocked: [String]
    /// The Live tab's relays: read relays plus zap.stream's.
    var relays: [String]

    static let empty = NVLiveHandoff(generatedAt: .distantPast, follows: [], followListIsKnown: false,
                                     blocked: [], relays: [])
}

/// One stream row, ready to draw.
struct NVLiveTile: Equatable, Identifiable {
    var id: String            // stream address
    var hostPubkey: String
    var name: String
    var pictureURL: URL?
    var title: String
    var link: URL
}

enum NVLiveNowLogic {
    /// Rows a widget family draws: small = the newest one, medium = up to three.
    static func rows(isSmall: Bool) -> Int { isSmall ? 1 : 3 }

    /// Relays the widget may ask. The vault's own relay is only up while the
    /// app runs (nobody is looking at the Home Screen then), and a `.fips`
    /// relay is reachable only over the mesh the widget does not have.
    static func askableRelays(_ relays: [String]) -> [URL] {
        var seen = Set<String>()
        return relays.compactMap { raw -> URL? in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: trimmed),
                  let scheme = url.scheme?.lowercased(), scheme == "wss" || scheme == "ws",
                  let host = url.host?.lowercased(),
                  host != "127.0.0.1", host != "localhost", host != "::1",
                  !host.hasSuffix(".fips"), !host.hasSuffix(".fips."),
                  seen.insert(trimmed.lowercased()).inserted else { return nil }
            return url
        }
    }

    /// The REQ filters for a follow list: by author and by `p` tag (zap.stream
    /// signs streams with its own key and names the streamer as Host), in
    /// chunks because relays cap filter sizes. Same shape as `LiveNowModel`.
    static func streamFilters(follows: [String], chunk: Int = 150) -> [[String: Any]] {
        var filters: [[String: Any]] = []
        for start in stride(from: 0, to: follows.count, by: chunk) {
            let part = Array(follows[start..<min(start + chunk, follows.count)])
            filters.append(["kinds": [30311], "authors": part, "limit": 100])
            filters.append(["kinds": [30311], "#p": part, "limit": 100])
        }
        return filters
    }

    /// The name and picture from a kind 0 content string.
    static func profile(fromContent content: String) -> (name: String?, picture: URL?) {
        guard let data = content.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return (nil, nil) }
        func text(_ key: String) -> String? {
            let value = (json[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == false ? value : nil
        }
        let picture = text("picture").flatMap { URL(string: $0) }.flatMap { url -> URL? in
            let scheme = url.scheme?.lowercased()
            return scheme == "https" || scheme == "http" ? url : nil
        }
        return (text("display_name") ?? text("name"), picture)
    }

    /// The name a row shows when the host's profile never arrived.
    static func fallbackName(_ pubkey: String) -> String { "npub…" + String(pubkey.suffix(6)) }
}

// MARK: - Deep link

/// `nostrvault://live?e=<base64url JSON>`: the stream event itself rides in
/// the link, so a tap opens the player at once instead of waiting on a relay
/// for an event the widget already had. Only what `LiveStream` reads is kept:
/// participant `p` tags (dozens on a busy stream) are dropped, except Host.
enum NVLiveLink {
    static let host = "live"

    struct Event: Equatable {
        var id: String
        var pubkey: String
        var createdAt: Int64
        var tags: [[String]]
    }

    static func url(id: String, pubkey: String, createdAt: Int64, tags: [[String]]) -> URL? {
        let kept = tags.filter { tag in
            guard tag.first == "p" else { return true }
            return tag.count >= 4 && tag[3].lowercased() == "host"
        }
        let object: [String: Any] = ["id": id, "pubkey": pubkey, "created_at": createdAt, "tags": kept]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        let encoded = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        var parts = URLComponents()
        parts.scheme = "nostrvault"
        parts.host = host
        parts.queryItems = [URLQueryItem(name: "e", value: encoded)]
        return parts.url
    }

    static func parse(_ url: URL) -> Event? {
        guard url.scheme == "nostrvault", url.host == host,
              let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "e" })?.value else { return nil }
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = json["id"] as? String, let pubkey = json["pubkey"] as? String,
              let createdAt = (json["created_at"] as? NSNumber)?.int64Value,
              let tags = json["tags"] as? [[String]] else { return nil }
        return Event(id: id, pubkey: pubkey, createdAt: createdAt, tags: tags)
    }
}
