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

    /// An artist's details, albums (newest first) and the songs on them.
    /// Songs come from the newest 25 albums; the albums row lists them all.
    func artistPage(_ id: String) async -> ArtistPage? {
        if let cached = artistPages[id] { return cached }
        guard let found = try? await WavlakeAPI.artistPage(id) else { return nil }
        let tracks = await WavlakeAPI.tracks(onAlbums: Array(found.albums.prefix(25)))
        let page = ArtistPage(artist: found.artist, albums: found.albums, tracks: tracks)
        // Every album failing is a bad connection, not an empty artist:
        // show it, but ask again next time.
        if !found.albums.isEmpty && tracks.isEmpty { return page }
        artistPages[id] = page
        return page
    }

    func albumPage(_ id: String) async -> AlbumPage? {
        if let cached = albumPages[id] { return cached }
        guard let found = try? await WavlakeAPI.albumPage(id), !found.tracks.isEmpty else { return nil }
        let page = AlbumPage(album: found.album, tracks: found.tracks)
        albumPages[id] = page
        return page
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

    /// Wavlake artists whose linked Nostr key you follow, and their ranked
    /// songs. Wavlake can't be asked which artists a key follows, and only
    /// an artist's own page carries their key, so this checks the artists
    /// of the last 90 days' rankings plus your recent artists.
    func followedArtists(follows: Set<String>) async -> (artists: [WavlakeArtist], tracks: [WavlakeTrack]) {
        let ranked = (try? await WavlakeAPI.trending(days: 90)) ?? []
        var ids: [String] = []
        for id in recentArtists.map(\.id) + ranked.compactMap(\.artistId) where !ids.contains(id) {
            ids.append(id)
        }
        let missing = ids.filter { artistCache[$0] == nil }
        await withTaskGroup(of: WavlakeArtist?.self) { group in
            for id in missing {
                group.addTask { try? await WavlakeAPI.artist(id) }
            }
            for await artist in group {
                if let artist { artistCache[artist.id] = artist }
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
