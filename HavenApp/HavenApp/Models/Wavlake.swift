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

    /// How long each kind of answer is used before Wavlake is asked again.
    enum MaxAge {
        /// Rankings are sums of sats; ten minutes barely moves them.
        static let rankings: TimeInterval = 10 * 60
        /// Albums and artist pages change when an artist uploads.
        static let page: TimeInterval = 60 * 60
        /// An artist's name, picture and linked key, for Following.
        static let artist: TimeInterval = 24 * 60 * 60
        /// A search typed again soon after.
        static let search: TimeInterval = 5 * 60
    }

    /// Rankings, albums and artists, kept on disk between launches.
    static let cache = WavlakeCache(
        directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Wavlake", isDirectory: true),
        loader: { try await fetch($0) })

    /// Searches, kept for this launch only.
    static let searchCache = WavlakeCache(directory: nil, loader: { try await fetch($0) })

    /// A kept answer, parsed, and whether it's young enough to skip asking
    /// Wavlake again.
    struct Kept<Value> {
        let value: Value
        let isFresh: Bool
    }

    /// What `cache` holds for `url`, without asking Wavlake.
    static func kept<Value>(_ url: URL, maxAge: TimeInterval, _ parse: (Data) -> Value) async -> Kept<Value>? {
        guard let hit = await cache.stored(url) else { return nil }
        return Kept(value: parse(hit.data), isFresh: await cache.isFresh(hit, maxAge: maxAge))
    }

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
        tracks(fromRankings: try await cache.data(rankingsURL(days: days), maxAge: MaxAge.rankings))
    }

    static func keptTrending(days: Int = 7) async -> Kept<[WavlakeTrack]>? {
        await kept(rankingsURL(days: days), maxAge: MaxAge.rankings, tracks(fromRankings:))
    }

    static func artist(_ id: String) async throws -> WavlakeArtist? {
        artist(fromArtist: try await cache.data(artistURL(id), maxAge: MaxAge.artist), id: id)
    }

    static func keptArtist(_ id: String) async -> Kept<WavlakeArtist?>? {
        await kept(artistURL(id), maxAge: MaxAge.artist) { artist(fromArtist: $0, id: id) }
    }

    static func search(_ term: String) async throws -> [WavlakeSearchResult] {
        guard let url = searchURL(term) else { return [] }
        return results(fromSearch: try await searchCache.data(url, maxAge: MaxAge.search))
    }

    /// One track by id. The endpoint answers with a one-element array.
    static func track(_ id: String) async throws -> WavlakeTrack? {
        tracks(fromRankings: try await fetch(trackURL(id))).first
    }

    static func album(_ id: String) async throws -> [WavlakeTrack] {
        tracks(fromAlbum: try await cache.data(albumURL(id), maxAge: MaxAge.page))
    }

    /// An album's heading and tracks, from one request.
    static func albumPage(_ id: String) async throws -> (album: WavlakeAlbum?, tracks: [WavlakeTrack]) {
        let data = try await cache.data(albumURL(id), maxAge: MaxAge.page)
        return (album(fromAlbum: data), tracks(fromAlbum: data))
    }

    static func keptAlbumPage(_ id: String) async -> Kept<(album: WavlakeAlbum?, tracks: [WavlakeTrack])>? {
        await kept(albumURL(id), maxAge: MaxAge.page) { (album(fromAlbum: $0), tracks(fromAlbum: $0)) }
    }

    /// An artist page's details and albums, from one request.
    static func artistPage(_ id: String) async throws -> (artist: WavlakeArtist?, albums: [WavlakeAlbum]) {
        let data = try await cache.data(artistURL(id), maxAge: MaxAge.page)
        return (artist(fromArtist: data, id: id), albums(fromArtist: data))
    }

    static func keptArtistPage(_ id: String) async -> Kept<(artist: WavlakeArtist?, albums: [WavlakeAlbum])>? {
        await kept(artistURL(id), maxAge: MaxAge.page) { (artist(fromArtist: $0, id: id), albums(fromArtist: $0)) }
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

    /// The kept tracks of `albums`, without asking Wavlake; nil unless
    /// every album is kept.
    static func keptTracks(onAlbums albums: [WavlakeAlbum]) async -> Kept<[WavlakeTrack]>? {
        var tracks: [WavlakeTrack] = []
        var isFresh = true
        for album in albums {
            guard let found = await kept(albumURL(album.id), maxAge: MaxAge.page, tracks(fromAlbum:)) else { return nil }
            tracks += found.value
            isFresh = isFresh && found.isFresh
        }
        return Kept(value: tracks, isFresh: isFresh)
    }
}

/// Wavlake answers kept between opens of the Music tab, and on disk so a
/// relaunch has them too. An answer younger than the caller's `maxAge` is
/// used without asking Wavlake; an older one is still there to show while
/// a new one loads. One address asked for twice at once is one request.
actor WavlakeCache {
    struct Hit {
        let data: Data
        let fetchedAt: Date
    }

    typealias Loader = @Sendable (URL) async throws -> Data

    private let directory: URL?
    private let now: @Sendable () -> Date
    private let loader: Loader
    private var memory: [URL: Hit] = [:]
    private var inFlight: [URL: Task<Data, Error>] = [:]

    /// `directory` nil keeps answers in memory only.
    init(directory: URL?, now: @escaping @Sendable () -> Date = { Date() }, loader: @escaping Loader) {
        self.directory = directory
        self.now = now
        self.loader = loader
    }

    /// What's kept for `url`, however old; nil when nothing is.
    func stored(_ url: URL) -> Hit? {
        if let hit = memory[url] { return hit }
        guard let file = file(for: url),
              let data = try? Data(contentsOf: file),
              let date = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
        else { return nil }
        let hit = Hit(data: data, fetchedAt: date)
        memory[url] = hit
        return hit
    }

    func isFresh(_ hit: Hit, maxAge: TimeInterval) -> Bool {
        now().timeIntervalSince(hit.fetchedAt) < maxAge
    }

    /// `url`'s answer: the kept one while younger than `maxAge`, otherwise
    /// a new one from Wavlake.
    func data(_ url: URL, maxAge: TimeInterval) async throws -> Data {
        if let hit = stored(url), isFresh(hit, maxAge: maxAge) { return hit.data }
        return try await load(url)
    }

    /// Asks Wavlake for `url`, joining a request for it already under way.
    func load(_ url: URL) async throws -> Data {
        if let running = inFlight[url] { return try await running.value }
        let loader = loader
        let task = Task { try await loader(url) }
        inFlight[url] = task
        defer { inFlight[url] = nil }
        let data = try await task.value
        keep(data, for: url)
        return data
    }

    private func keep(_ data: Data, for url: URL) {
        let date = now()
        memory[url] = Hit(data: data, fetchedAt: date)
        guard let directory, let file = file(for: url) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard (try? data.write(to: file, options: .atomic)) != nil else { return }
        // The file's date is when the answer came, so a relaunch knows its age.
        try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
    }

    /// One file per address, named by the address itself.
    private func file(for url: URL) -> URL? {
        guard let directory else { return nil }
        let name = Data(url.absoluteString.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
        return directory.appendingPathComponent(name)
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

/// Music by someone the active account has blocked.
///
/// Wavlake only names an artist's Nostr key on the artist's own page, so a
/// blocked artist is recognised two ways: by the key, when a song or a page
/// carries one, and otherwise by their Wavlake artist id once any page seen
/// this launch has named that key. Nothing is removed from Wavlake or from
/// the saved artist list, so an unblock shows them again.
///
/// The gap this leaves: an artist never opened, played or followed has no
/// known key, so their songs can still rank in Trending until a page naming
/// their key is read.
enum WavlakeBlockFilter {
    /// The Wavlake ids of every known artist whose linked key is blocked.
    /// `hex` turns an npub into a hex pubkey, matching `blocked`.
    static func blockedArtistIds(known: [WavlakeArtist], blocked: Set<String>,
                                 hex: (String) -> String?) -> Set<String> {
        guard !blocked.isEmpty else { return [] }
        var ids = Set<String>()
        for artist in known {
            guard let npub = artist.npub, let key = hex(npub), blocked.contains(key) else { continue }
            ids.insert(artist.id)
        }
        return ids
    }

    static func isBlocked(npub: String?, artistId: String?, blocked: Set<String>,
                          artistIds: Set<String>, hex: (String) -> String?) -> Bool {
        if blocked.isEmpty && artistIds.isEmpty { return false }
        if let npub, let key = hex(npub), blocked.contains(key) { return true }
        if let artistId, artistIds.contains(artistId) { return true }
        return false
    }

    static func tracks(_ tracks: [WavlakeTrack], blocked: Set<String>,
                       artistIds: Set<String>, hex: (String) -> String?) -> [WavlakeTrack] {
        if blocked.isEmpty && artistIds.isEmpty { return tracks }
        return tracks.filter {
            !isBlocked(npub: $0.artistNpub, artistId: $0.artistId,
                       blocked: blocked, artistIds: artistIds, hex: hex)
        }
    }

    static func artists(_ artists: [WavlakeArtist], blocked: Set<String>,
                        artistIds: Set<String>, hex: (String) -> String?) -> [WavlakeArtist] {
        if blocked.isEmpty && artistIds.isEmpty { return artists }
        return artists.filter {
            !isBlocked(npub: $0.npub, artistId: $0.id,
                       blocked: blocked, artistIds: artistIds, hex: hex)
        }
    }

    /// One row of a search: the track rows by their own key or artist id,
    /// the artist rows by id. Search carries no keys, so an artist row only
    /// drops once a page has named their key.
    static func results(_ results: [WavlakeSearchResult], blocked: Set<String>,
                        artistIds: Set<String>, hex: (String) -> String?) -> [WavlakeSearchResult] {
        if blocked.isEmpty && artistIds.isEmpty { return results }
        return results.filter { result in
            switch result {
            case .track(let track):
                return !isBlocked(npub: track.artistNpub, artistId: track.artistId,
                                  blocked: blocked, artistIds: artistIds, hex: hex)
            case .artist(let id, _, _):
                return !artistIds.contains(id)
            case .album:
                return true
            }
        }
    }
}
