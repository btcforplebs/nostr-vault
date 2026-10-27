import AVKit
import Combine
import SwiftUI

// MARK: - Music feed

/// What the Music feed shows. The top-right toolbar sets it and
/// MusicBrowserView reads it, so the two stay in step across tabs.
@MainActor
final class MusicFeedState: ObservableObject {
    static let shared = MusicFeedState()

    enum Scope: Equatable {
        case trending
        case artist(WavlakeArtist)
        case following
    }

    /// The rankings windows offered as words. Wavlake answers 1 to 90 days.
    enum TrendingWindow: Int, CaseIterable {
        case week = 7
        case month = 30

        var title: String { self == .week ? "This week" : "This month" }
    }

    /// An artist or album opened inside the feed.
    enum Page: Hashable {
        case artist(WavlakeArtist)
        case album(WavlakeAlbum)
    }

    /// Any toolbar pick, even the one already showing, closes open pages
    /// and the search.
    @Published var scope: Scope = .trending { didSet { path = []; picks += 1 } }
    /// Counts toolbar picks, so the feed can clear its search on a pick
    /// that doesn't change what loads.
    @Published private(set) var picks = 0
    /// Pages opened over the toolbar's choice; the last one is showing.
    @Published private(set) var path: [Page] = []
    @Published var trendingWindow: TrendingWindow = .week
    /// Artists you've played or opened, newest first.
    @Published private(set) var recentArtists: [WavlakeArtist] = []

    private static let recentKey = "music.recentArtists"
    private static let maxRecent = 20
    /// Artist pages fetched this launch, for their Nostr keys. A missing
    /// key is cached too (npub nil), so Following doesn't ask twice.
    private var artistCache: [String: WavlakeArtist] = [:]
    private var cancellables = Set<AnyCancellable>()
    /// Pages already loaded this launch, so Back and forth don't refetch.
    private var artistPages: [String: ArtistPage] = [:]
    private var albumPages: [String: AlbumPage] = [:]

    struct ArtistPage {
        var artist: WavlakeArtist?
        var albums: [WavlakeAlbum]
        var tracks: [WavlakeTrack]
    }

    struct AlbumPage {
        var album: WavlakeAlbum?
        var tracks: [WavlakeTrack]
    }

    /// What a toolbar choice showed, kept so opening the tab again draws
    /// it at once instead of starting from a spinner.
    struct Listing {
        var tracks: [WavlakeTrack] = []
        /// Following: the artists found, shown above their songs.
        var artists: [WavlakeArtist] = []
        var message: String?

        var isEmpty: Bool { tracks.isEmpty && artists.isEmpty }
    }

    @Published private(set) var listings: [String: Listing] = [:]

    /// Names the toolbar's current choice; changes whenever it picks
    /// something else to show.
    var listingKey: String {
        switch scope {
        case .trending: return "trending:\(trendingWindow.rawValue)"
        case .artist(let artist): return "artist:\(artist.id)"
        case .following: return "following"
        }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.recentKey),
           let saved = try? JSONDecoder().decode([WavlakeArtist].self, from: data) {
            recentArtists = saved
        }
        // Every song that starts, from this feed or a post, adds its artist.
        // Queue and index publish separately; settle before reading them.
        let player = MusicPlayerService.shared
        player.$queue.combineLatest(player.$index)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .compactMap { queue, index in queue.indices.contains(index) ? queue[index].wavlake : nil }
            .removeDuplicates { $0.artistId == $1.artistId }
            .sink { [weak self] track in self?.remember(track) }
            .store(in: &cancellables)
    }

    func remember(_ track: WavlakeTrack) {
        guard let id = track.artistId else { return }
        remember(WavlakeArtist(id: id, name: track.artist, artUrl: track.artistArtUrl, npub: track.artistNpub))
    }

    func remember(_ artist: WavlakeArtist) {
        var artist = artist
        let known = recentArtists.first { $0.id == artist.id }
        artist.artUrl = artist.artUrl ?? known?.artUrl
        artist.npub = artist.npub ?? known?.npub
        recentArtists = Array(([artist] + recentArtists.filter { $0.id != artist.id }).prefix(Self.maxRecent))
        saveRecent()
    }

    /// Every artist whose Nostr key is known this launch: the saved recents
    /// plus the pages fetched. Rankings and search carry no key, so this is
    /// what makes a blocked artist recognisable there.
    var knownArtists: [WavlakeArtist] { recentArtists + Array(artistCache.values) }

    /// The Wavlake ids of known artists the active account blocks.
    var blockedArtistIds: Set<String> {
        WavlakeBlockFilter.blockedArtistIds(
            known: knownArtists,
            blocked: ConfigService.shared.activeAccountBlockedHexPubkeys,
            hex: MusicSheet.hex(fromNpub:))
    }

    func clearRecentArtists() {
        recentArtists = []
        saveRecent()
    }

    var currentArtist: WavlakeArtist? {
        if case .artist(let artist) = scope { return artist }
        return nil
    }

    func show(_ artist: WavlakeArtist) {
        remember(artist)
        scope = .artist(artist)
    }

    func open(_ page: Page) {
        guard path.last != page else { return }
        if case .artist(let artist) = page { remember(artist) }
        path.append(page)
    }

    func goBack() {
        _ = path.popLast()
    }

    /// Opens an artist or album from anywhere (the full player, the mini
    /// player, another tab): switches to the Music feed first if it isn't
    /// showing, so the page has somewhere to open.
    func reveal(_ page: Page) {
        if FeedService.shared.feedMode == .music {
            open(page)
        } else {
            FeedService.shared.switchMode(.music)
            if case .artist(let artist) = page { remember(artist) }
            path = [page]
        }
        NotificationCenter.default.post(name: .havenOpenFeed, object: nil)
    }

    /// The artist or album on screen right now, so a song's "Go to" actions
    /// don't offer the page you're already on.
    var showingArtistId: String? {
        guard FeedService.shared.feedMode == .music else { return nil }
        switch path.last {
        case .artist(let artist): return artist.id
        case .album: return nil
        case nil: return currentArtist?.id
        }
    }

    var showingAlbumId: String? {
        guard FeedService.shared.feedMode == .music else { return nil }
        if case .album(let album) = path.last { return album.id }
        return nil
    }

    /// The page for a song's artist or album, when Wavlake says which.
    static func artistPage(of track: WavlakeTrack) -> Page? {
        track.artistId.map { .artist(WavlakeArtist(id: $0, name: track.artist, artUrl: track.artistArtUrl, npub: track.artistNpub)) }
    }

    static func albumPage(of track: WavlakeTrack) -> Page? {
        track.albumId.map {
            .album(WavlakeAlbum(id: $0, title: track.albumTitle ?? "Album", artUrl: track.albumArtUrl,
                                artist: track.artist, artistId: track.artistId))
        }
    }

    /// Songs come from an artist's newest 25 albums; the albums row lists
    /// them all.
    private static let artistPageAlbums = 25

    /// An artist's details, albums (newest first) and the songs on them.
    /// A page kept from an earlier launch shows at once; when it's gone
    /// stale it's asked for again behind it, ready for the next open.
    func artistPage(_ id: String) async -> ArtistPage? {
        if let cached = artistPages[id] { return cached }
        if let kept = await WavlakeAPI.keptArtistPage(id),
           let tracks = await WavlakeAPI.keptTracks(onAlbums: Array(kept.value.albums.prefix(Self.artistPageAlbums))),
           kept.value.albums.isEmpty || !tracks.value.isEmpty {
            let page = ArtistPage(artist: kept.value.artist, albums: kept.value.albums, tracks: tracks.value)
            artistPages[id] = page
            if !(kept.isFresh && tracks.isFresh) { Task { await fetchArtistPage(id) } }
            return page
        }
        return await fetchArtistPage(id)
    }

    @discardableResult
    private func fetchArtistPage(_ id: String) async -> ArtistPage? {
        guard let found = try? await WavlakeAPI.artistPage(id) else { return nil }
        let tracks = await WavlakeAPI.tracks(onAlbums: Array(found.albums.prefix(Self.artistPageAlbums)))
        let page = ArtistPage(artist: found.artist, albums: found.albums, tracks: tracks)
        // Every album failing is a bad connection, not an empty artist:
        // show it, but ask again next time.
        if !found.albums.isEmpty && tracks.isEmpty { return page }
        artistPages[id] = page
        return page
    }

    /// An album's heading and songs; kept ones first, like artistPage.
    func albumPage(_ id: String) async -> AlbumPage? {
        if let cached = albumPages[id] { return cached }
        if let kept = await WavlakeAPI.keptAlbumPage(id), !kept.value.tracks.isEmpty {
            let page = AlbumPage(album: kept.value.album, tracks: kept.value.tracks)
            albumPages[id] = page
            if !kept.isFresh { Task { await fetchAlbumPage(id) } }
            return page
        }
        return await fetchAlbumPage(id)
    }

    @discardableResult
    private func fetchAlbumPage(_ id: String) async -> AlbumPage? {
        guard let found = try? await WavlakeAPI.albumPage(id), !found.tracks.isEmpty else { return nil }
        let page = AlbumPage(album: found.album, tracks: found.tracks)
        albumPages[id] = page
        return page
    }

    /// Fills the toolbar choice's listing. What's kept shows first; then
    /// Wavlake is asked only for what has gone stale, so reopening the
    /// tab within minutes asks for nothing. A bad connection leaves kept
    /// songs up rather than swapping them for an error.
    func loadListing() async {
        let key = listingKey
        switch scope {
        case .trending:
            let days = trendingWindow.rawValue
            if listings[key] == nil, let kept = await WavlakeAPI.keptTrending(days: days), !kept.value.isEmpty {
                listings[key] = Listing(tracks: kept.value)
            }
            do {
                let found = try await WavlakeAPI.trending(days: days)
                listings[key] = Listing(tracks: found, message: found.isEmpty ? "Nothing trending right now." : nil)
            } catch {
                if listings[key]?.isEmpty ?? true {
                    listings[key] = Listing(message: "Couldn't reach Wavlake. Tap to try again.")
                }
            }
        case .artist:
            // MusicArtistPage loads itself.
            break
        case .following:
            let follows = Set(FeedService.shared.followedPubkeys)
            guard !follows.isEmpty else {
                listings[key] = Listing(message: "Follow people on Nostr, and the Wavlake artists among them show up here.")
                return
            }
            if listings[key] == nil {
                let kept = await followedArtists(follows: follows, keptOnly: true)
                if !kept.artists.isEmpty { listings[key] = Listing(tracks: kept.tracks, artists: kept.artists) }
            }
            let found = await followedArtists(follows: follows)
            listings[key] = Listing(
                tracks: found.tracks, artists: found.artists,
                message: found.artists.isEmpty
                    ? "None of the Wavlake artists checked are people you follow. Artists show up here once they link their Nostr key on Wavlake."
                    : nil)
        }
    }

    func showTrending(_ window: TrendingWindow) {
        trendingWindow = window
        scope = .trending
    }

    private func saveRecent() {
        if let data = try? JSONEncoder().encode(recentArtists) {
            UserDefaults.standard.set(data, forKey: Self.recentKey)
        }
    }

    private static let artistLookupsAtOnce = 6

    /// Wavlake artists whose linked Nostr key you follow, and their ranked
    /// songs. Wavlake can't be asked which artists a key follows, and only
    /// an artist's own page carries their key, so this checks the artists
    /// of the last 90 days' rankings plus your recent artists. `keptOnly`
    /// answers from what's already kept, without asking Wavlake; artists
    /// still unknown are left out of that answer.
    func followedArtists(follows: Set<String>, keptOnly: Bool = false)
        async -> (artists: [WavlakeArtist], tracks: [WavlakeTrack]) {
        let ranked = keptOnly
            ? (await WavlakeAPI.keptTrending(days: 90))?.value ?? []
            : (try? await WavlakeAPI.trending(days: 90)) ?? []
        var ids: [String] = []
        for id in recentArtists.map(\.id) + ranked.compactMap(\.artistId) where !ids.contains(id) {
            ids.append(id)
        }
        // Every artist goes through the cache: a kept one costs no request,
        // and one gone stale is asked for again. A few at a time: sixty at
        // once has Wavlake drop a third of them, and holds up every other
        // request to it behind the ones still waiting.
        await withTaskGroup(of: WavlakeArtist?.self) { group in
            var queue = ids[...]
            func next() {
                guard let id = queue.popFirst() else { return }
                group.addTask {
                    keptOnly ? (await WavlakeAPI.keptArtist(id))?.value ?? nil : try? await WavlakeAPI.artist(id)
                }
            }
            for _ in 0..<Self.artistLookupsAtOnce { next() }
            for await artist in group {
                if let artist { artistCache[artist.id] = artist }
                next()
            }
        }
        let blocked = ConfigService.shared.activeAccountBlockedHexPubkeys
        let artists = ids.compactMap { artistCache[$0] }.filter { artist in
            guard let key = artist.npub.flatMap(MusicSheet.hex(fromNpub:)) else { return false }
            return follows.contains(key) && !blocked.contains(key)
        }
        let followed = Set(artists.map(\.id))
        return (artists, ranked.filter { $0.artistId.map(followed.contains) ?? false })
    }
}
