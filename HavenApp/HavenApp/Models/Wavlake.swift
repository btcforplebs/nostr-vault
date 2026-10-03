import Foundation

/// A playable Wavlake track. Wavlake's public catalogue API returns direct
/// MP3 links (`mediaUrl`), so the app plays them natively: in the
/// background, with lock-screen controls. mynostrspace.com embeds Wavlake's
/// web player instead, which a browser tab can't keep alive.
struct WavlakeTrack: Identifiable, Hashable, Codable {
    let id: String
    let title: String
    let artist: String
    let artistId: String?
    let albumId: String?
    let albumTitle: String?
    let albumArtUrl: String?
    let mediaUrl: String
    let duration: Int?
    let msatTotal: String?
    /// The artist's Nostr key, when they've linked one on Wavlake.
    var artistNpub: String? = nil
    var artistArtUrl: String? = nil

    var audioURL: URL? { URL(string: mediaUrl) }
    var artworkURL: URL? { albumArtUrl.flatMap(URL.init(string:)) }
    var pageURL: URL? { URL(string: "https://wavlake.com/track/\(id)") }

    /// Sats earned, from Wavlake's millisat total.
    var sats: Int? { msatTotal.flatMap(Int.init).map { $0 / 1000 } }
}

/// One row of a Wavlake search: a track (playable now), or an album or
/// artist to open.
enum WavlakeSearchResult: Identifiable, Hashable {
    case track(WavlakeTrack)
    case album(id: String, title: String, artUrl: String?)
    case artist(id: String, name: String, artUrl: String?)

    var id: String {
        switch self {
        case .track(let t): return "track:\(t.id)"
        case .album(let id, _, _): return "album:\(id)"
        case .artist(let id, _, _): return "artist:\(id)"
        }
    }
}

/// A Wavlake artist, as the Music toolbar lists them.
struct WavlakeArtist: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    var artUrl: String?
    var npub: String?

    var artURL: URL? { artUrl.flatMap(URL.init(string:)) }
}

/// A Wavlake album, as an artist page lists it and an album page heads it.
struct WavlakeAlbum: Identifiable, Hashable, Codable {
    let id: String
    let title: String
    var artUrl: String?
    var artist: String?
    var artistId: String?
    /// Release year, from Wavlake's ISO release date.
    var year: Int?

    var artURL: URL? { artUrl.flatMap(URL.init(string:)) }
}

enum WavlakeAPI {
    static let base = URL(string: "https://wavlake.com/api/v1/content")!

    /// Top tracks by sats earned over the last `days` days.
    static func rankingsURL(days: Int = 7) -> URL {
        URL(string: "\(base.absoluteString)/rankings?sort=sats&days=\(days)")!
    }

    static func searchURL(_ term: String) -> URL? {
        var components = URLComponents(url: base.appendingPathComponent("search"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "term", value: term)]
        return components?.url
    }

    static func trackURL(_ id: String) -> URL { base.appendingPathComponent("track/\(id)") }
    static func albumURL(_ id: String) -> URL { base.appendingPathComponent("album/\(id)") }
    static func artistURL(_ id: String) -> URL { base.appendingPathComponent("artist/\(id)") }

    // MARK: - Parsing

    /// A track from any Wavlake payload (rankings, search, album). Rows
    /// without an http(s) MP3 link are dropped: there is nothing to play.
    static func track(from json: [String: Any], artistFallback: String? = nil) -> WavlakeTrack? {
        guard let id = json["id"] as? String,
              let mediaUrl = json["mediaUrl"] as? String,
              let scheme = URL(string: mediaUrl)?.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else { return nil }
        let title = (json["title"] as? String) ?? (json["name"] as? String) ?? "Untitled"
        let artist = (json["artist"] as? String) ?? artistFallback ?? "Unknown artist"
        let msat: String? = (json["msatTotal"] as? String) ?? (json["msatTotal"] as? Int).map(String.init)
        return WavlakeTrack(
            id: id,
            title: title,
            artist: artist,
            artistId: json["artistId"] as? String,
            albumId: json["albumId"] as? String,
            albumTitle: json["albumTitle"] as? String,
            albumArtUrl: json["albumArtUrl"] as? String,
            mediaUrl: mediaUrl,
            duration: (json["duration"] as? Int) ?? (json["duration"] as? Double).map { Int($0) },
            msatTotal: msat,
            artistNpub: (json["artistNpub"] as? String).flatMap { $0.hasPrefix("npub1") ? $0 : nil },
            artistArtUrl: json["artistArtUrl"] as? String
        )
    }

    static func tracks(fromRankings data: Data) -> [WavlakeTrack] {
        guard let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return rows.compactMap { track(from: $0) }
    }

    static func results(fromSearch data: Data) -> [WavlakeSearchResult] {
        guard let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            let name = (row["name"] as? String) ?? (row["title"] as? String) ?? ""
            switch row["type"] as? String {
            case "track":
                return track(from: row).map(WavlakeSearchResult.track)
            case "album":
                return .album(id: id, title: name, artUrl: row["albumArtUrl"] as? String)
            case "artist":
                return .artist(id: id, name: name, artUrl: row["artistArtUrl"] as? String)
            default:
                return nil
            }
        }
    }

    /// An album's tracks in album order. Album tracks carry no `artist` of
    /// their own on some albums, so the album's artist fills in.
    static func tracks(fromAlbum data: Data) -> [WavlakeTrack] {
        guard let album = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rows = album["tracks"] as? [[String: Any]] else { return [] }
        let artist = album["artist"] as? String
        return rows.compactMap { track(from: $0, artistFallback: artist) }
    }

    /// An artist's albums, newest release first. Wavlake lists them oldest
    /// first; undated albums go last.
    static func albums(fromArtist data: Data) -> [WavlakeAlbum] {
        guard let artist = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rows = artist["albums"] as? [[String: Any]] else { return [] }
        let name = artist["name"] as? String
        let dated = rows.compactMap { row -> (album: WavlakeAlbum, date: String)? in
            guard let album = album(from: row, artistFallback: name) else { return nil }
            return (album, (row["releaseDate"] as? String) ?? "")
        }
        // ISO dates sort as strings; stable, so same-day albums keep order.
        return dated.enumerated()
            .sorted { a, b in a.element.date != b.element.date ? a.element.date > b.element.date : a.offset < b.offset }
            .map(\.element.album)
    }

    /// An album's heading: title, cover, artist and year.
    static func album(fromAlbum data: Data) -> WavlakeAlbum? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return album(from: json)
    }

    static func album(from json: [String: Any], artistFallback: String? = nil) -> WavlakeAlbum? {
        guard let id = json["id"] as? String else { return nil }
        let title = (json["title"] as? String) ?? (json["name"] as? String) ?? "Untitled"
        return WavlakeAlbum(
            id: id,
            title: title,
            artUrl: json["albumArtUrl"] as? String,
            artist: (json["artist"] as? String) ?? artistFallback,
            artistId: json["artistId"] as? String,
            year: (json["releaseDate"] as? String).flatMap { Int($0.prefix(4)) }
        )
    }

    /// An artist page's name, picture and Nostr key. Rankings and search
    /// leave the key out; only this endpoint (and a single track) carry it.
    static func artist(fromArtist data: Data, id: String) -> WavlakeArtist? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let name = (json["name"] as? String) ?? (json["title"] as? String) ?? ""
        guard !name.isEmpty else { return nil }
        return WavlakeArtist(
            id: id,
            name: name,
            artUrl: json["artistArtUrl"] as? String,
            npub: (json["artistNpub"] as? String).flatMap { $0.hasPrefix("npub1") ? $0 : nil }
        )
    }

    // MARK: - Fetching

    static func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }

    /// Wavlake answers 1 to 90 days; anything longer is a 400.
    static func trending(days: Int = 7) async throws -> [WavlakeTrack] {
        tracks(fromRankings: try await fetch(rankingsURL(days: days)))
    }

    static func artist(_ id: String) async throws -> WavlakeArtist? {
        artist(fromArtist: try await fetch(artistURL(id)), id: id)
    }

    static func search(_ term: String) async throws -> [WavlakeSearchResult] {
        guard let url = searchURL(term) else { return [] }
        return results(fromSearch: try await fetch(url))
    }

    /// One track by id. The endpoint answers with a one-element array.
    static func track(_ id: String) async throws -> WavlakeTrack? {
        tracks(fromRankings: try await fetch(trackURL(id))).first
    }

    static func album(_ id: String) async throws -> [WavlakeTrack] {
        tracks(fromAlbum: try await fetch(albumURL(id)))
    }

    /// An album's heading and tracks, from one request.
    static func albumPage(_ id: String) async throws -> (album: WavlakeAlbum?, tracks: [WavlakeTrack]) {
        let data = try await fetch(albumURL(id))
        return (album(fromAlbum: data), tracks(fromAlbum: data))
    }

    /// An artist page's details and albums, from one request.
    static func artistPage(_ id: String) async throws -> (artist: WavlakeArtist?, albums: [WavlakeAlbum]) {
        let data = try await fetch(artistURL(id))
        return (artist(fromArtist: data, id: id), albums(fromArtist: data))
    }

    /// Every track on `albums`, album by album in the order given. The
    /// albums load side by side; one that fails is left out.
    static func tracks(onAlbums albums: [WavlakeAlbum]) async -> [WavlakeTrack] {
        var byAlbum: [String: [WavlakeTrack]] = [:]
        await withTaskGroup(of: (String, [WavlakeTrack]).self) { group in
            for album in albums {
                group.addTask { (album.id, (try? await WavlakeAPI.album(album.id)) ?? []) }
            }
            for await (id, tracks) in group { byAlbum[id] = tracks }
        }
        return albums.flatMap { byAlbum[$0.id] ?? [] }
    }
}

/// Wavlake links as they appear in Nostr posts.
enum WavlakeLink {
    /// The track id in wavlake.com/track/<id> or embed.wavlake.com/track/<id>.
    static func trackId(from url: URL) -> String? {
        guard let host = url.host?.lowercased(),
              host == "wavlake.com" || host.hasSuffix(".wavlake.com") else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2, parts[parts.count - 2].lowercased() == "track" else { return nil }
        let id = parts[parts.count - 1]
        // Wavlake ids are UUIDs; anything else is some other page.
        return UUID(uuidString: id) != nil ? id.lowercased() : nil
    }

    /// What "Share" puts in the composer: the song, the artist (mentioned
    /// when they're on Nostr, so they're notified) and the link that plays
    /// in any client with a Wavlake card.
    static func shareText(for track: WavlakeTrack) -> String {
        let by = track.artistNpub.map { "nostr:\($0)" } ?? track.artist
        return "🎵 \(track.title) by \(by)\n\nhttps://wavlake.com/track/\(track.id)"
    }
}
