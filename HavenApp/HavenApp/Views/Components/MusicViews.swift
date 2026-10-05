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
        let artists = ids.compactMap { artistCache[$0] }.filter { artist in
            artist.npub.flatMap(MusicSheet.hex(fromNpub:)).map(follows.contains) ?? false
        }
        let followed = Set(artists.map(\.id))
        return (artists, ranked.filter { $0.artistId.map(followed.contains) ?? false })
    }
}

/// The Music feed: Wavlake's trending tracks, and search across tracks,
/// albums and artists. Tapping a track plays it and queues the rest of the
/// list after it; the mini player keeps going while you browse.
struct MusicBrowserView: View {
    @ObservedObject private var player = MusicPlayerService.shared
    @ObservedObject private var feed = MusicFeedState.shared
    @State private var sheet: MusicSheet?
    @State private var query = ""
    /// The songs for the toolbar's current choice.
    @State private var tracks: [WavlakeTrack] = []
    /// Following: the artists found, shown above their songs.
    @State private var followedArtists: [WavlakeArtist] = []
    @State private var results: [WavlakeSearchResult] = []
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var searchTask: Task<Void, Never>?
    /// Search keeps its own spinner and message, so clearing a search
    /// can't stop the toolbar choice's load, or the other way round.
    @State private var isSearching = false
    @State private var searchError: String?

    var body: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 12) {
                // Opening or leaving a page starts it at its top.
                Color.clear.frame(height: 0).id(Self.topAnchor)

                if let page = feed.path.last {
                    pageView(page)
                        .id(page)
                } else {
                    searchField

                    if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                        searchResults
                    } else {
                        scopeContent
                    }

                    status
                }

                Link(destination: URL(string: "https://wavlake.com")!) {
                    Text("Music from Wavlake")
                        .font(.appSystem(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                }
                .padding(.vertical, 16)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .onChange(of: feed.path) { _, _ in proxy.scrollTo(Self.topAnchor, anchor: .top) }
        }
        .task(id: loadKey) { await load() }
        // A toolbar pick replaces whatever search was showing.
        .onChange(of: feed.picks) { _, _ in query = "" }
        .modifier(MusicSheetHost(sheet: $sheet))
    }

    private static let topAnchor = "music.top"

    @ViewBuilder
    private func pageView(_ page: MusicFeedState.Page) -> some View {
        switch page {
        case .artist(let artist):
            MusicArtistPage(artist: artist, sheet: $sheet, onBack: feed.goBack)
        case .album(let album):
            MusicAlbumPage(album: album, sheet: $sheet, onBack: feed.goBack)
        }
    }

    /// The spinner or message under the toolbar's choice or a search.
    @ViewBuilder
    private var status: some View {
        if isBrowsing ? isLoading : isSearching {
            ProgressView().tint(.havenPurple).frame(maxWidth: .infinity).padding(.vertical, 30)
        } else if let message = isBrowsing ? errorText : searchError {
            Text(message)
                .font(.appSystem(size: 14))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
                .contentShape(Rectangle())
                .accessibilityAddTraits(isBrowsing ? .isButton : [])
                .onTapGesture {
                    if isBrowsing { Task { await load() } }
                }
        }
    }

    /// Showing the toolbar's choice rather than search.
    private var isBrowsing: Bool { query.isEmpty }

    /// Changes whenever the toolbar picks something else to show.
    private var loadKey: String {
        switch feed.scope {
        case .trending: return "trending:\(feed.trendingWindow.rawValue)"
        case .artist(let artist): return "artist:\(artist.id)"
        case .following: return "following"
        }
    }

    @ViewBuilder
    private var scopeContent: some View {
        switch feed.scope {
        case .trending:
            let window = feed.trendingWindow.title.lowercased()
            if !feed.recentArtists.isEmpty {
                header("Your artists") { EmptyView() }
                artistRow(feed.recentArtists)
            }
            if !trendingArtists.isEmpty {
                header("Top artists \(window)") { EmptyView() }
                artistRow(trendingArtists)
            }
            if !trendingAlbums.isEmpty {
                header("Top albums \(window)") { EmptyView() }
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(trendingAlbums) { album in
                            MusicCollectionTile(title: album.title, subtitle: album.artist ?? "Album",
                                                art: album.artURL, round: false, size: 130) {
                                feed.open(.album(album))
                            }
                        }
                    }
                }
            }
            header("Trending songs \(window)") { EmptyView() }
            trackList(tracks)
        case .artist(let artist):
            MusicArtistPage(artist: artist, sheet: $sheet) { feed.scope = .trending }
                .id(artist.id)
        case .following:
            if !followedArtists.isEmpty {
                header("Artists you follow") { EmptyView() }
                artistRow(followedArtists)
            }
            if !tracks.isEmpty {
                header("Their songs") { EmptyView() }
                trackList(tracks)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundColor(.secondary)
            TextField("Search songs, albums, artists", text: $query)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                #endif
                .onChange(of: query) { _, _ in scheduleSearch() }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.12)))
    }

    private func header<Accessory: View>(_ title: String, @ViewBuilder accessory: () -> Accessory) -> some View {
        MusicSectionHeader(title: title, accessory: accessory)
    }

    /// Round artist pictures in a sideways row; tap one for their page.
    private func artistRow(_ artists: [WavlakeArtist]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(artists) { artist in
                    MusicCollectionTile(title: artist.name, subtitle: "Artist", art: artist.artURL, round: true, size: 96) {
                        feed.open(.artist(artist))
                    }
                }
            }
        }
    }

    /// Trending is ranked by song, so its artists and albums come out in
    /// the order their best song places. A row this long is plenty.
    private static let rowLimit = 15

    private var trendingArtists: [WavlakeArtist] {
        var seen = Set<String>()
        return tracks.compactMap { track -> WavlakeArtist? in
            guard let id = track.artistId, seen.insert(id).inserted else { return nil }
            return WavlakeArtist(id: id, name: track.artist, artUrl: track.artistArtUrl, npub: track.artistNpub)
        }
        .prefix(Self.rowLimit).map { $0 }
    }

    private var trendingAlbums: [WavlakeAlbum] {
        var seen = Set<String>()
        return tracks.compactMap { track -> WavlakeAlbum? in
            guard let id = track.albumId, seen.insert(id).inserted else { return nil }
            return WavlakeAlbum(id: id, title: track.albumTitle ?? "Album", artUrl: track.albumArtUrl,
                                artist: track.artist, artistId: track.artistId)
        }
        .prefix(Self.rowLimit).map { $0 }
    }

    private func trackList(_ tracks: [WavlakeTrack]) -> some View {
        MusicTrackList(tracks: tracks, sheet: $sheet)
    }

    @ViewBuilder
    private var searchResults: some View {
        let tracks = results.compactMap { if case .track(let t) = $0 { return t } else { return nil } }
        let collections = results.filter { if case .track = $0 { return false } else { return true } }
        if !collections.isEmpty {
            header("Albums and artists") { EmptyView() }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(collections) { result in
                        collectionCard(result)
                    }
                }
            }
        }
        if !tracks.isEmpty {
            header("Songs") { EmptyView() }
            trackList(tracks)
        }
    }

    @ViewBuilder
    private func collectionCard(_ result: WavlakeSearchResult) -> some View {
        switch result {
        case .album(let id, let title, let art):
            MusicCollectionTile(title: title, subtitle: "Album", art: art.flatMap(URL.init(string:)), round: false) {
                feed.open(.album(WavlakeAlbum(id: id, title: title, artUrl: art)))
            }
        case .artist(let id, let name, let art):
            MusicCollectionTile(title: name, subtitle: "Artist", art: art.flatMap(URL.init(string:)), round: true) {
                feed.open(.artist(WavlakeArtist(id: id, name: name, artUrl: art)))
            }
        case .track:
            EmptyView()
        }
    }

    // MARK: - Loading

    private func load() async {
        tracks = []
        followedArtists = []
        isLoading = true
        errorText = nil
        var found: [WavlakeTrack] = []
        var artists: [WavlakeArtist] = []
        var message: String?
        switch feed.scope {
        case .trending:
            do {
                found = try await WavlakeAPI.trending(days: feed.trendingWindow.rawValue)
                if found.isEmpty { message = "Nothing trending right now." }
            } catch {
                message = "Couldn't reach Wavlake. Tap to try again."
            }
        case .artist:
            // MusicArtistPage loads itself.
            break
        case .following:
            let follows = Set(FeedService.shared.followedPubkeys)
            if follows.isEmpty {
                message = "Follow people on Nostr, and the Wavlake artists among them show up here."
            } else {
                (artists, found) = await feed.followedArtists(follows: follows)
                if artists.isEmpty {
                    message = "None of the Wavlake artists checked are people you follow. Artists show up here once they link their Nostr key on Wavlake."
                }
            }
        }
        // A newer choice took over while this one loaded; it owns the page.
        guard !Task.isCancelled else { return }
        tracks = found
        followedArtists = artists
        errorText = message
        isLoading = false
    }

    /// Searches once typing pauses, so each keystroke isn't a request.
    private func scheduleSearch() {
        searchTask?.cancel()
        let term = query.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { results = []; searchError = nil; isSearching = false; return }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            isSearching = true
            searchError = nil
            let found = (try? await WavlakeAPI.search(term)) ?? []
            guard !Task.isCancelled else { return }
            results = found
            isSearching = false
            if found.isEmpty { searchError = "No music found for \"\(term)\"." }
        }
    }
}

// MARK: - Artist and album pages

/// An artist's page: their picture and name, Play and Shuffle, a row of
/// albums (newest first) to open, then every song.
struct MusicArtistPage: View {
    let artist: WavlakeArtist
    @Binding var sheet: MusicSheet?
    let onBack: () -> Void
    @ObservedObject private var player = MusicPlayerService.shared
    @ObservedObject private var feed = MusicFeedState.shared
    @State private var page: MusicFeedState.ArtistPage?
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            MusicBackButton(action: onBack)

            VStack(spacing: 8) {
                MusicArtwork(url: shown.artURL, size: 148)
                    .clipShape(Circle())
                    .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
                Text(shown.name)
                    .font(.appSystem(size: 26, weight: .bold))
                    .multilineTextAlignment(.center)
                if let summary {
                    Text(summary).font(.appSystem(size: 13)).foregroundColor(.secondary)
                }
                MusicPlayButtons(tracks: page?.tracks ?? []) {
                    if let hex = shown.npub.flatMap(MusicSheet.hex(fromNpub:)) {
                        MusicPillButton(title: "On Nostr", icon: "person.crop.circle", filled: false) {
                            sheet = .profile(hex)
                        }
                    }
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity)

            if isLoading {
                ProgressView().tint(.havenPurple).frame(maxWidth: .infinity).padding(.vertical, 30)
            } else if let page, !page.tracks.isEmpty || !page.albums.isEmpty {
                if !page.albums.isEmpty {
                    MusicSectionHeader(title: page.albums.count == 1 ? "Album" : "Albums") { EmptyView() }
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 14) {
                            ForEach(page.albums) { album in
                                MusicCollectionTile(title: album.title, subtitle: album.year.map(String.init) ?? "Album",
                                                    art: album.artURL, round: false, size: 140) {
                                    feed.open(.album(album))
                                }
                            }
                        }
                    }
                }
                if !page.tracks.isEmpty {
                    MusicSectionHeader(title: "Songs") { EmptyView() }
                    MusicTrackList(tracks: page.tracks, sheet: $sheet)
                }
            } else {
                MusicRetryMessage(text: "Couldn't load \(shown.name). Tap to try again.") {
                    Task { await load() }
                }
            }
        }
        .task { await load() }
    }

    /// The fetched details once they're in; what was tapped until then.
    private var shown: WavlakeArtist {
        guard var found = page?.artist else { return artist }
        found.artUrl = found.artUrl ?? artist.artUrl
        found.npub = found.npub ?? artist.npub
        return found
    }

    private var summary: String? {
        guard let page, !page.albums.isEmpty else { return nil }
        return [MusicCount.albums(page.albums.count), page.tracks.isEmpty ? nil : MusicCount.songs(page.tracks.count)]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private func load() async {
        isLoading = true
        let found = await feed.artistPage(artist.id)
        guard !Task.isCancelled else { return }
        page = found
        isLoading = false
    }
}

/// An album's page: the cover, its artist (tap to open them), year and
/// length, Play and Shuffle, and the songs in album order.
struct MusicAlbumPage: View {
    let album: WavlakeAlbum
    @Binding var sheet: MusicSheet?
    let onBack: () -> Void
    @ObservedObject private var feed = MusicFeedState.shared
    @State private var page: MusicFeedState.AlbumPage?
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            MusicBackButton(action: onBack)

            VStack(spacing: 6) {
                MusicArtwork(url: shown.artURL, size: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .shadow(color: .black.opacity(0.3), radius: 14, y: 6)
                    .padding(.bottom, 6)
                Text(shown.title)
                    .font(.appSystem(size: 22, weight: .bold))
                    .multilineTextAlignment(.center)
                if let name = shown.artist {
                    if let artistId = shown.artistId {
                        Button { openArtist(id: artistId, name: name) } label: {
                            Text(name).font(.appSystem(size: 16, weight: .semibold)).foregroundColor(.havenPurple)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens the artist")
                    } else {
                        Text(name).font(.appSystem(size: 16, weight: .semibold)).foregroundColor(.secondary)
                    }
                }
                if let summary {
                    Text(summary).font(.appSystem(size: 13)).foregroundColor(.secondary)
                }
                MusicPlayButtons(tracks: page?.tracks ?? []) { EmptyView() }
                    .padding(.top, 6)
            }
            .frame(maxWidth: .infinity)

            if isLoading {
                ProgressView().tint(.havenPurple).frame(maxWidth: .infinity).padding(.vertical, 30)
            } else if let page {
                MusicTrackList(tracks: page.tracks, sheet: $sheet, numbered: true)
            } else {
                MusicRetryMessage(text: "Couldn't load \(album.title). Tap to try again.") {
                    Task { await load() }
                }
            }
        }
        .task { await load() }
    }

    private var shown: WavlakeAlbum {
        guard var found = page?.album else { return album }
        found.artUrl = found.artUrl ?? album.artUrl
        found.artist = found.artist ?? album.artist ?? page?.tracks.first?.artist
        found.artistId = found.artistId ?? album.artistId ?? page?.tracks.first?.artistId
        return found
    }

    private var summary: String? {
        guard let page else { return shown.year.map(String.init) }
        let seconds = page.tracks.compactMap(\.duration).reduce(0, +)
        return [shown.year.map(String.init), MusicCount.songs(page.tracks.count),
                seconds > 0 ? MusicCount.minutes(seconds) : nil]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    /// Opened from that artist's page, Back is the way there; otherwise
    /// open the artist on top.
    private func openArtist(id: String, name: String) {
        let path = feed.path
        let cameFromArtist: Bool
        if path.count >= 2, case .artist(let previous) = path[path.count - 2] {
            cameFromArtist = previous.id == id
        } else {
            cameFromArtist = path.count == 1 && feed.currentArtist?.id == id
        }
        if cameFromArtist {
            feed.goBack()
        } else {
            let art = page?.tracks.first(where: { $0.artistId == id })?.artistArtUrl
            feed.open(.artist(WavlakeArtist(id: id, name: name, artUrl: art)))
        }
    }

    private func load() async {
        isLoading = true
        let found = await feed.albumPage(album.id)
        guard !Task.isCancelled else { return }
        page = found
        isLoading = false
    }
}

enum MusicCount {
    static func songs(_ n: Int) -> String { n == 1 ? "1 song" : "\(n) songs" }
    static func albums(_ n: Int) -> String { n == 1 ? "1 album" : "\(n) albums" }
    static func minutes(_ seconds: Int) -> String {
        let minutes = max(1, Int((Double(seconds) / 60).rounded()))
        return minutes >= 60 ? "\(minutes / 60) hr \(minutes % 60) min" : "\(minutes) min"
    }
}

/// A page's songs. Tap plays from that song on (or pauses the one
/// playing); long-press shares or opens its artist or album.
struct MusicTrackList: View {
    let tracks: [WavlakeTrack]
    @Binding var sheet: MusicSheet?
    /// Album order: a track number in place of the cover.
    var numbered = false
    @ObservedObject private var player = MusicPlayerService.shared

    var body: some View {
        LazyVStack(spacing: 4) {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { offset, track in
                HStack(spacing: 0) {
                    MusicTrackRow(track: track, isCurrent: player.current?.id == track.id, isPlaying: player.isPlaying,
                                  number: numbered ? offset + 1 : nil)
                        .contentShape(Rectangle())
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityHint(player.current?.id == track.id && player.isPlaying ? "Pauses the song" : "Plays the song")
                        .onTapGesture {
                            if player.current?.id == track.id {
                                player.togglePlayPause()
                            } else {
                                player.play(tracks, startAt: offset)
                            }
                        }
                    // The same actions as a long-press, in plain sight.
                    MusicMoreMenu(label: "More for \(track.title)") {
                        MusicTrackActions(track: track, sheet: $sheet)
                    }
                }
                .contextMenu { MusicTrackActions(track: track, sheet: $sheet) }
            }
        }
    }
}

/// Play from the top and Shuffle, plus any extra pill (an artist's Nostr
/// profile). Disabled until there are songs.
struct MusicPlayButtons<Extra: View>: View {
    let tracks: [WavlakeTrack]
    @ViewBuilder let extra: () -> Extra
    @ObservedObject private var player = MusicPlayerService.shared

    var body: some View {
        HStack(spacing: 10) {
            MusicPillButton(title: "Play", icon: "play.fill", filled: true) { player.play(tracks) }
            MusicPillButton(title: "Shuffle", icon: "shuffle", filled: false) { player.playShuffled(tracks) }
            extra()
        }
        .disabled(tracks.isEmpty)
        .opacity(tracks.isEmpty ? 0.5 : 1)
    }
}

struct MusicPillButton: View {
    let title: String
    let icon: String
    let filled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.appSystem(size: 14, weight: .semibold))
                .foregroundColor(filled ? .white : .havenPurple)
                .padding(.horizontal, 16)
                .frame(minHeight: 36)
                .background(Capsule().fill(filled ? Color.havenPurple : Color.havenPurple.opacity(0.14)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// A song's ⋯: its long-press actions behind a visible button.
struct MusicMoreMenu<Items: View>: View {
    let label: String
    @ViewBuilder let items: () -> Items

    var body: some View {
        Menu {
            items()
        } label: {
            Image(systemName: "ellipsis")
                .font(.appSystem(size: 15, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 36, height: 44)
                .contentShape(Rectangle())
        }
        .menuIndicator(.hidden)
        #if os(macOS)
        // .borderlessButton flattens the label's modifiers on macOS.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .help(label)
        #endif
        .accessibilityLabel(label)
    }
}

/// Go to the playing song's artist or album, for the mini player's and the
/// folded bar's long-press.
struct MusicNowPlayingPageActions: View {
    let track: PlayerTrack

    var body: some View {
        if let song = track.wavlake {
            if let page = MusicFeedState.artistPage(of: song) {
                Button { MusicFeedState.shared.reveal(page) } label: {
                    Label("Go to \(song.artist)", systemImage: "music.mic")
                }
            }
            if let page = MusicFeedState.albumPage(of: song) {
                Button { MusicFeedState.shared.reveal(page) } label: {
                    Label(song.albumTitle.map { "Go to \($0)" } ?? "Go to album", systemImage: "square.stack")
                }
            }
        }
    }
}

struct MusicBackButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Back", systemImage: "chevron.left")
                .font(.appSystem(size: 15, weight: .semibold))
                .frame(minHeight: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(.havenPurple)
    }
}

struct MusicSectionHeader<Accessory: View>: View {
    let title: String
    let accessory: Accessory

    init(title: String, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.accessory = accessory()
    }

    var body: some View {
        HStack {
            accessory
            Text(title).font(.appSystem(size: 18, weight: .bold)).accessibilityAddTraits(.isHeader)
            Spacer()
        }
        .padding(.top, 4)
    }
}

/// An album or artist to open: square cover, or a round picture for artists.
struct MusicCollectionTile: View {
    let title: String
    let subtitle: String
    let art: URL?
    let round: Bool
    var size: CGFloat = 110
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                MusicArtwork(url: art, size: size)
                    .clipShape(round ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 10)))
                Text(title).font(.appSystem(size: 13, weight: .semibold)).lineLimit(2)
                Text(subtitle).font(.appSystem(size: 11)).foregroundColor(.secondary)
            }
            .frame(width: size, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(round ? "Opens the artist" : "Opens the album")
    }
}

struct MusicRetryMessage: View {
    let text: String
    let retry: () -> Void

    var body: some View {
        Text(text)
            .font(.appSystem(size: 14))
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 30)
            .contentShape(Rectangle())
            .accessibilityAddTraits(.isButton)
            .onTapGesture(perform: retry)
    }
}

/// The Music feed's top-right controls: Trending (this week or month),
/// an artist picker, and Wavlake artists you follow on Nostr.
struct MusicToolbarButtons: View {
    @ObservedObject private var feed = MusicFeedState.shared

    var body: some View {
        HStack(spacing: 4) {
            toolbarMenu(icon: isTrending ? "flame.fill" : "flame", label: "Trending", isSelected: isTrending) {
                MusicTrendingMenuItems()
            }
            toolbarMenu(icon: artist != nil ? "person.crop.circle.fill" : "person.crop.circle",
                        label: artist.map { "Artist: \($0.name)" } ?? "Artists", isSelected: artist != nil) {
                MusicArtistMenuItems()
            }
            IconFilterButton(icon: isFollowing ? "person.2.fill" : "person.2", tooltip: "Artists you follow",
                             isSelected: isFollowing, color: .havenPurple) {
                feed.scope = .following
            }
            #if os(macOS)
            .help("Wavlake artists you follow on Nostr")
            #endif
        }
    }

    private var isTrending: Bool { feed.scope == .trending }
    private var isFollowing: Bool { feed.scope == .following }
    private var artist: WavlakeArtist? { feed.currentArtist }

    private func toolbarMenu<Items: View>(icon: String, label: String, isSelected: Bool, @ViewBuilder items: () -> Items) -> some View {
        Menu {
            items()
        } label: {
            Image(systemName: icon)
                .font(.appSystem(size: 15, weight: .semibold))
                .foregroundColor(isSelected ? .havenPurple : .secondary)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
                .animation(Motion.toggle, value: isSelected)
        }
        .menuIndicator(.hidden)
        #if os(macOS)
        // .borderlessButton flattens the label's modifiers on macOS.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .help(label)
        #endif
        .accessibilityLabel(label)
    }
}

/// This week / This month, for the toolbar's Trending menu and the
/// compact toolbar's single menu.
struct MusicTrendingMenuItems: View {
    @ObservedObject private var feed = MusicFeedState.shared

    var body: some View {
        ForEach(MusicFeedState.TrendingWindow.allCases, id: \.self) { window in
            Button { feed.showTrending(window) } label: {
                Label("Trending \(window.title.lowercased())",
                      systemImage: feed.scope == .trending && feed.trendingWindow == window ? "checkmark" : "flame")
            }
        }
    }
}

/// Artists you've played or opened, newest first.
struct MusicArtistMenuItems: View {
    @ObservedObject private var feed = MusicFeedState.shared

    var body: some View {
        if feed.recentArtists.isEmpty {
            Text("Artists you play or open show up here")
        } else {
            ForEach(feed.recentArtists) { artist in
                Button { feed.show(artist) } label: {
                    Label(artist.name, systemImage: feed.currentArtist?.id == artist.id ? "checkmark" : "person.crop.circle")
                }
            }
            Divider()
            Button(role: .destructive) { feed.clearRecentArtists() } label: {
                Label("Clear artists", systemImage: "trash")
            }
        }
    }
}

/// Everything in MusicToolbarButtons, as items for the compact toolbar menu.
struct MusicToolbarMenuItems: View {
    @ObservedObject private var feed = MusicFeedState.shared

    var body: some View {
        MusicTrendingMenuItems()
        Button { feed.scope = .following } label: {
            Label("Artists you follow", systemImage: feed.scope == .following ? "checkmark" : "person.2")
        }
        Menu {
            MusicArtistMenuItems()
        } label: {
            Label("Artists", systemImage: "person.crop.circle")
        }
    }
}

struct MusicTrackRow: View {
    let track: WavlakeTrack
    let isCurrent: Bool
    let isPlaying: Bool
    /// Album order: the track number shows instead of the cover.
    var number: Int? = nil

    var body: some View {
        HStack(spacing: 12) {
            if let number {
                Group {
                    if isCurrent {
                        Image(systemName: isPlaying ? "waveform" : "play.fill")
                            .font(.appSystem(size: 14, weight: .bold))
                            .foregroundColor(.havenPurple)
                    } else {
                        Text("\(number)")
                            .font(.appSystem(size: 15, weight: .semibold).monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                }
                .frame(width: 28, height: 40)
            } else {
            ZStack {
                MusicArtwork(url: track.artworkURL, size: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                if isCurrent {
                    RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.45)).frame(width: 48, height: 48)
                    Image(systemName: isPlaying ? "waveform" : "play.fill")
                        .font(.appSystem(size: 18, weight: .bold))
                        .foregroundColor(.white)
                }
            }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.appSystem(size: 15, weight: .semibold))
                    .foregroundColor(isCurrent ? .havenPurple : .primary)
                    .lineLimit(1)
                Text(track.artist)
                    .font(.appSystem(size: 13))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let sats = track.sats, sats > 0 {
                Label("\(sats.formatted())", systemImage: "bolt.fill")
                    .font(.appSystem(size: 11, weight: .semibold))
                    .foregroundColor(.orange)
                    .labelStyle(.titleAndIcon)
            }
            if let duration = track.duration, duration > 0 {
                Text(MusicTime.format(Double(duration)))
                    .font(.appSystem(size: 12).monospacedDigit())
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 6)
    }
}

struct MusicArtwork: View {
    let url: URL?
    let size: CGFloat
    /// A load cut off by the page swapping in (opening an artist from the
    /// player switches tab and feed at once) fails for good; try again.
    @State private var retries = 0

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else if phase.error != nil, retries < 2 {
                        placeholder.task {
                            try? await Task.sleep(nanoseconds: 400_000_000)
                            retries += 1
                        }
                    } else {
                        placeholder
                    }
                }
                .id(retries)
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipped()
    }

    private var placeholder: some View {
        ZStack {
            Color.secondary.opacity(0.15)
            Image(systemName: "music.note").foregroundColor(.secondary)
        }
    }
}

enum MusicTime {
    static func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Mini player

/// Sits above the tab bar whenever a track is loaded, on every tab: artwork,
/// title, play/pause and next, with a thin progress line. Tap it for the
/// full controls; the ✕ stops the music and hides it.
struct MiniPlayerBar: View {
    @ObservedObject private var player = MusicPlayerService.shared
    @ObservedObject private var row = FloatingButtonRow.shared
    @State private var showingFull = false

    /// Same height as the floating Post / Blossom / Relay capsule, so the
    /// two read as one row.
    static let height: CGFloat = FloatingButtonRow.buttonHeight

    var body: some View {
        if let track = player.current {
            // Sharing the row with a floating button leaves no room for skip;
            // play and ✕ stay, and skip lives in the full player.
            let compact = row.reservedWidth > 0
            HStack(spacing: 8) {
                // Round, so it sits inside the capsule's end instead of
                // poking its corners out of the curve.
                MusicArtwork(url: track.artworkURL, size: 40)
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title).font(.appSystem(size: 14, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 5) {
                        if track.isLive { LiveBadge() }
                        Text(track.artist).font(.appSystem(size: 12)).foregroundColor(.secondary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Opens the player")
                .accessibilityAction { showingFull = true }
                if player.isBuffering && player.isPlaying {
                    ProgressView().controlSize(.small).frame(width: 44, height: 44)
                } else {
                    Button(action: player.togglePlayPause) {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.appSystem(size: 18, weight: .bold))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                }
                if !track.isLive && !compact {
                    Button(action: player.next) {
                        Image(systemName: "forward.fill")
                            .font(.appSystem(size: 15, weight: .bold))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!player.hasNext)
                    .opacity(player.hasNext ? 1 : 0.35)
                    .accessibilityLabel("Next song")
                }
                Button(action: player.stop) {
                    Image(systemName: "xmark")
                        .font(.appSystem(size: 13, weight: .bold))
                        .foregroundColor(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop music")
            }
            .padding(.leading, 4)
            .frame(height: Self.height)
            .overlay(alignment: .bottom) {
                // Progress along the bottom edge, inside the bar.
                GeometryReader { geo in
                    Capsule()
                        .fill(Color.havenPurple)
                        .frame(width: !track.isLive && player.duration > 0 ? geo.size.width * min(1, player.elapsed / player.duration) : 0)
                }
                .frame(height: 2)
                .padding(.horizontal, 14)
                .padding(.bottom, 2)
            }
            .foregroundColor(.primary)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
            .contentShape(Capsule())
            .onTapGesture { showingFull = true }
            .contextMenu {
                Button { showingFull = true } label: { Label("Open player", systemImage: "music.note") }
                MusicNowPlayingPageActions(track: track)
            }
            .sheet(isPresented: $showingFull) { PlayerSheet() }
        }
    }
}

/// The folded tab bar's stand-in for the mini player: the cover as a small
/// disc with play/pause on it and the song's progress around its edge, left
/// of the avatar. Nothing at all when nothing is loaded, so the folded bar
/// is unchanged without music.
struct CollapsedNowPlayingButton: View {
    @ObservedObject private var player = MusicPlayerService.shared
    @State private var showingFull = false

    private static let size: CGFloat = 36

    var body: some View {
        if let track = player.current {
            let progress = !track.isLive && player.duration > 0
                ? min(1, player.elapsed / player.duration) : 0
            Button(action: player.togglePlayPause) {
                ZStack {
                    MusicArtwork(url: track.artworkURL, size: Self.size)
                        .clipShape(Circle())
                    Circle().fill(Color.black.opacity(0.45))
                    if player.isBuffering && player.isPlaying {
                        ProgressView().controlSize(.mini).tint(.white)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.appSystem(size: 13, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
                .frame(width: Self.size, height: Self.size)
                .overlay {
                    // Live has no progress: a steady red ring says "on air".
                    Circle()
                        .stroke(track.isLive ? Color.red.opacity(0.8) : Color.white.opacity(0.2), lineWidth: 2)
                    if !track.isLive {
                        Circle()
                            .trim(from: 0, to: progress)
                            .stroke(Color.havenPurple, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                }
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            .accessibilityValue("\(track.title), \(track.artist)")
            .accessibilityAction(named: "Open player") { showingFull = true }
            .contextMenu {
                Button { showingFull = true } label: { Label("Open player", systemImage: "music.note") }
                MusicNowPlayingPageActions(track: track)
            }
            .sheet(isPresented: $showingFull) { PlayerSheet() }
        }
    }
}

// MARK: - Floating button row

/// Shares the row above the iPhone tab bar between the mini player and the
/// screen's floating button (Post, Blossom, Relay). Each floating button
/// reports its width here; the mini player stops short of it, with a gap,
/// and the button drops level with the mini player. With nothing playing the
/// button stays exactly where it always was.
@MainActor
final class FloatingButtonRow: ObservableObject {
    static let shared = FloatingButtonRow()
    static let buttonHeight: CGFloat = 48
    /// Where a floating button sits when no music is playing.
    static let defaultBottom: CGFloat = 90
    static let trailingInset: CGFloat = 20
    static let gap: CGFloat = 10

    /// Space the mini player leaves on its right: the visible button's
    /// width, its trailing inset and the gap. Zero when no button is showing.
    @Published private(set) var reservedWidth: CGFloat = 0
    /// Bottom padding for floating buttons, from the bottom safe area:
    /// level with the mini player while it's showing.
    @Published private(set) var buttonBottom: CGFloat = defaultBottom

    private var widths: [UUID: CGFloat] = [:]
    private var tabBarOnlyHeight: CGFloat = 0
    private var miniPlayerShowing = false

    func report(_ id: UUID, width: CGFloat?) {
        widths[id] = width
        let widest = widths.values.max() ?? 0
        reservedWidth = widest > 0 ? widest + Self.trailingInset + Self.gap : 0
    }

    func update(tabBarOnlyHeight: CGFloat, miniPlayerShowing: Bool) {
        self.tabBarOnlyHeight = tabBarOnlyHeight
        self.miniPlayerShowing = miniPlayerShowing
        // The mini player sits 6pt above the tab bar (the inset's spacing).
        buttonBottom = miniPlayerShowing && tabBarOnlyHeight > 0
            ? tabBarOnlyHeight + 6
            : Self.defaultBottom
    }
}

/// Places a floating button (Post, Blossom, Relay) in the row above the tab
/// bar and reports its width so the mini player can make room for it.
///
/// Where there is no iPhone tab bar (the iPad split, macOS) there's no row to
/// share: the button sits at the ordinary 20pt margin and reports nothing.
struct FloatingButtonSlot: ViewModifier {
    @ObservedObject private var row = FloatingButtonRow.shared
    @Environment(\.floatingTabBarHeight) private var tabBarHeight
    @State private var id = UUID()

    func body(content: Content) -> some View {
        let sharesRow = tabBarHeight > 0
        content
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { if sharesRow { row.report(id, width: geo.size.width) } }
                        .onChange(of: geo.size.width) { _, width in if sharesRow { row.report(id, width: width) } }
                }
            )
            .onDisappear { row.report(id, width: nil) }
            .padding(.trailing, FloatingButtonRow.trailingInset)
            .padding(.bottom, sharesRow ? row.buttonBottom : 20)
            .animation(Motion.chrome, value: row.buttonBottom)
    }
}

/// Docks the mini player at the bottom of a screen when no iPhone tab bar
/// is carrying it (`floatingTabBarHeight` is 0 on iPad and Mac).
struct MiniPlayerInset: ViewModifier {
    @Environment(\.floatingTabBarHeight) private var tabBarHeight

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            if tabBarHeight == 0 {
                MiniPlayerBar().padding(.bottom, 10)
            }
        }
    }
}

/// Full player: the cover (or Up Next) over a blur of it, the song with its
/// artist and album as links into the Music feed, scrubber, shuffle /
/// previous / play / next / repeat, and AirPlay, Up Next and more along
/// the bottom.
/// What opening the mini player shows: a minimized live stream pops back
/// out into its full window (video, chat and all) and keeps playing; a song
/// opens the music player.
struct PlayerSheet: View {
    @ObservedObject private var player = MusicPlayerService.shared

    var body: some View {
        if player.current?.isLive == true, let stream = player.liveStream {
            LiveStreamPlayerView(stream: stream)
                .environmentObject(NostrService.shared)
                .environmentObject(ConfigService.shared)
                // The window paused the small player to play its own video.
                // Swiped away, the stream carries on in the small player
                // rather than going silent.
                .onDisappear {
                    if player.current?.isLive == true, !player.isPlaying { player.resume() }
                }
        } else {
            NowPlayingView()
        }
    }
}

struct NowPlayingView: View {
    @ObservedObject private var player = MusicPlayerService.shared
    @Environment(\.dismiss) private var dismiss
    @State private var scrubbing: Double?
    @State private var sheet: MusicSheet?
    @State private var showingQueue = false

    private static let artSize: CGFloat = 280

    var body: some View {
        VStack(spacing: 18) {
            Capsule().fill(Color.secondary.opacity(0.4)).frame(width: 40, height: 5).padding(.top, 10)
            if let track = player.current {
                Group {
                    if showingQueue {
                        upNext
                    } else {
                        MusicArtwork(url: track.artworkURL, size: Self.artSize)
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                            .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
                            .accessibilityHidden(true)
                    }
                }
                .frame(height: Self.artSize)
                .transition(.opacity)

                titles(track)

                if !track.isLive { scrubber }

                transport(track)

                pageButtons(track)

                Spacer(minLength: 0)

                bottomBar(track)
            } else {
                Text("Nothing playing").foregroundColor(.secondary)
                    .onAppear { dismiss() }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 12)
        .background { backdrop }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 640)
        #endif
        .presentationDetents([.large])
        .modifier(MusicSheetHost(sheet: $sheet))
    }

    // MARK: Pieces

    /// The cover, blown up and blurred under a material, so the player
    /// takes on the song's colours and text stays readable in light and dark.
    private var backdrop: some View {
        ZStack {
            if let url = player.current?.artworkURL {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Color.clear
                }
                .blur(radius: 50)
                .opacity(0.8)
            }
            Rectangle().fill(.regularMaterial)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    /// Title, then the artist and album, each opening its page.
    private func titles(_ track: PlayerTrack) -> some View {
        VStack(spacing: 4) {
            if track.isLive { LiveBadge() }
            Text(track.title).font(.appSystem(size: 22, weight: .bold)).multilineTextAlignment(.center).lineLimit(2)
            if let song = track.wavlake, let page = MusicFeedState.artistPage(of: song) {
                linkText(track.artist, size: 16, weight: .semibold, hint: "Opens the artist") { go(page) }
            } else {
                Text(track.artist).font(.appSystem(size: 16)).foregroundColor(.secondary)
            }
            if let song = track.wavlake, let album = song.albumTitle, album != track.title,
               let page = MusicFeedState.albumPage(of: song) {
                linkText(album, size: 13, weight: .regular, hint: "Opens the album") { go(page) }
            }
        }
        .padding(.horizontal, 24)
    }

    private func linkText(_ text: String, size: CGFloat, weight: Font.Weight, hint: String,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(text).lineLimit(1)
                Image(systemName: "chevron.right").font(.appSystem(size: size - 4, weight: .semibold))
            }
            .font(.appSystem(size: size, weight: weight))
            .foregroundColor(.havenPurple)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(hint)
    }

    private var scrubber: some View {
        VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { scrubbing ?? player.elapsed },
                    set: { scrubbing = $0 }
                ),
                in: 0...max(player.duration, 1),
                onEditingChanged: { editing in
                    if !editing, let target = scrubbing {
                        player.seek(to: target)
                        scrubbing = nil
                    }
                }
            )
            .tint(.havenPurple)
            HStack {
                Text(MusicTime.format(scrubbing ?? player.elapsed))
                Spacer()
                Text(MusicTime.format(player.duration))
            }
            .font(.appSystem(size: 12).monospacedDigit())
            .foregroundColor(.secondary)
        }
        .padding(.horizontal, 28)
    }

    /// Shuffle and repeat flank the usual three; live has only play/pause.
    private func transport(_ track: PlayerTrack) -> some View {
        HStack(spacing: 0) {
            modeButton(icon: "shuffle", isOn: player.isShuffled, label: "Shuffle",
                       value: player.isShuffled ? "On" : "Off", action: player.toggleShuffle)
                .opacity(track.isLive ? 0 : 1)
                .disabled(track.isLive)
            Spacer()
            Button(action: player.previous) {
                Image(systemName: "backward.fill").font(.appSystem(size: 26))
            }
            .opacity(track.isLive ? 0 : 1)
            .disabled(track.isLive)
            .accessibilityLabel("Previous")
            Spacer()
            Button(action: player.togglePlayPause) {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.appSystem(size: 64))
                    .foregroundColor(.havenPurple)
            }
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            Spacer()
            Button(action: player.next) {
                Image(systemName: "forward.fill").font(.appSystem(size: 26))
            }
            .disabled(!player.hasNext)
            .opacity(track.isLive ? 0 : (player.hasNext ? 1 : 0.35))
            .accessibilityLabel("Next")
            Spacer()
            modeButton(icon: player.repeatMode == .one ? "repeat.1" : "repeat", isOn: player.repeatMode != .off,
                       label: "Repeat", value: repeatValue, action: player.cycleRepeat)
                .opacity(track.isLive ? 0 : 1)
                .disabled(track.isLive)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 28)
    }

    private var repeatValue: String {
        switch player.repeatMode {
        case .off: return "Off"
        case .all: return "All"
        case .one: return "This song"
        }
    }

    /// Shuffle or repeat: purple on a soft purple disc when on.
    private func modeButton(icon: String, isOn: Bool, label: String, value: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.appSystem(size: 17, weight: .semibold))
                .foregroundColor(isOn ? .havenPurple : .secondary)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color.havenPurple.opacity(isOn ? 0.18 : 0)))
                .contentShape(Circle())
                .animation(Motion.toggle, value: isOn)
        }
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }

    /// Where a song leads: its artist and album pages, and Share. A live
    /// stream offers its video and host.
    @ViewBuilder
    private func pageButtons(_ track: PlayerTrack) -> some View {
        HStack(spacing: 10) {
            if let song = track.wavlake {
                if let page = MusicFeedState.artistPage(of: song) {
                    actionButton("Artist", icon: "music.mic") { go(page) }
                }
                if let page = MusicFeedState.albumPage(of: song) {
                    actionButton("Album", icon: "square.stack") { go(page) }
                }
                actionButton("Share", icon: "square.and.arrow.up") {
                    sheet = .share(WavlakeLink.shareText(for: song))
                }
            } else if let host = track.hostPubkey {
                if let stream = player.liveStream {
                    actionButton("Watch", icon: "play.rectangle") { sheet = .live(stream) }
                }
                actionButton("Host", icon: "person.crop.circle") { sheet = .profile(host) }
            }
        }
    }

    private func actionButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.appSystem(size: 14, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color.secondary.opacity(0.15)))
        }
        .buttonStyle(.plain)
    }

    /// AirPlay, Up Next, and the song's other actions.
    private func bottomBar(_ track: PlayerTrack) -> some View {
        HStack {
            AirPlayButton()
                .frame(width: 44, height: 44)
                .accessibilityLabel("AirPlay")
            Spacer()
            if !track.isLive {
                Button {
                    withAnimation(Motion.toggle) { showingQueue.toggle() }
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.appSystem(size: 18, weight: .semibold))
                        .foregroundColor(showingQueue ? .havenPurple : .secondary)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Color.havenPurple.opacity(showingQueue ? 0.18 : 0)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Up Next")
                .accessibilityValue(showingQueue ? "Showing" : "Hidden")
                Spacer()
            }
            if let song = track.wavlake {
                MusicMoreMenu(label: "More for \(song.title)") {
                    // Artist and Album are buttons right above.
                    MusicTrackActions(track: song, sheet: $sheet, opensPages: false)
                }
                .frame(width: 44, height: 44)
            } else {
                Color.clear.frame(width: 44, height: 44)
            }
        }
        .padding(.horizontal, 28)
    }

    /// The songs after this one; tap one to play it now.
    private var upNext: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Up Next").font(.appSystem(size: 17, weight: .bold)).accessibilityAddTraits(.isHeader)
                Spacer()
                if player.isShuffled {
                    Label("Shuffled", systemImage: "shuffle").font(.appSystem(size: 12, weight: .semibold))
                        .foregroundColor(.havenPurple)
                }
            }
            let upcoming = Array(player.upNext.enumerated())
            if upcoming.isEmpty {
                Text(player.repeatMode == .all ? "The queue starts over after this song."
                                               : "Nothing after this song.")
                    .font(.appSystem(size: 14))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(upcoming, id: \.element.id) { offset, item in
                            Button { player.jump(to: player.index + 1 + offset) } label: {
                                HStack(spacing: 10) {
                                    MusicArtwork(url: item.artworkURL, size: 40)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(item.title).font(.appSystem(size: 14, weight: .semibold)).lineLimit(1)
                                        Text(item.artist).font(.appSystem(size: 12)).foregroundColor(.secondary).lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                    if let duration = item.duration, duration > 0 {
                                        Text(MusicTime.format(Double(duration)))
                                            .font(.appSystem(size: 12).monospacedDigit())
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Plays this song now")
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 24)
    }

    /// Closes the player and opens the page in the Music feed. The page
    /// opens once the sheet is on its way out, so the switch to the feed
    /// tab doesn't happen under it.
    private func go(_ page: MusicFeedState.Page) {
        dismiss()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            MusicFeedState.shared.reveal(page)
        }
    }
}

/// The system AirPlay / output picker, for sending music to a speaker.
#if os(iOS)
struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .secondaryLabel
        view.activeTintColor = UIColor(Color.havenPurple)
        view.prioritizesVideoDevices = false
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
#else
struct AirPlayButton: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.isRoutePickerButtonBordered = false
        return view
    }

    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {}
}
#endif


// MARK: - Sharing, artists, live

struct LiveBadge: View {
    var body: some View {
        Text("LIVE")
            .font(.appSystem(size: 10, weight: .heavy))
            .foregroundColor(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.red))
    }
}

/// The two places a song leads: a post sharing it, or the artist's Nostr
/// profile (which carries Follow and Zap).
enum MusicSheet: Identifiable {
    case share(String)
    case profile(String)
    case live(LiveStream)

    var id: String {
        switch self {
        case .share(let text): return "share:\(text)"
        case .profile(let hex): return "profile:\(hex)"
        case .live(let stream): return "live:\(stream.id)"
        }
    }

    static func hex(fromNpub npub: String) -> String? {
        guard let decoded = Bech32.decode(npub), decoded.hrp == "npub" else { return nil }
        return decoded.hexString
    }
}

struct MusicSheetHost: ViewModifier {
    @Binding var sheet: MusicSheet?
    @EnvironmentObject private var nostrService: NostrService
    @EnvironmentObject private var configService: ConfigService
    @EnvironmentObject private var relayManager: RelayProcessManager

    func body(content: Content) -> some View {
        content.sheet(item: $sheet) { item in
            switch item {
            case .share(let text):
                ComposeView(onDismiss: { sheet = nil }, replyTo: nil, quoteTo: nil, initialContent: text, restoredDraftId: nil)
                    .environmentObject(nostrService)
                    .environmentObject(configService)
                    .environmentObject(relayManager)
            case .live(let stream):
                LiveStreamPlayerView(stream: stream)
                    .environmentObject(nostrService)
                    .environmentObject(configService)
            case .profile(let hex):
                ProfileView(pubkey: hex, onDismiss: { sheet = nil })
                    .environmentObject(nostrService)
                    .environmentObject(configService)
                    #if os(macOS)
                    .frame(minWidth: 520, minHeight: 560)
                    #endif
            }
        }
    }
}

/// Long-press actions on a song.
struct MusicTrackActions: View {
    let track: WavlakeTrack
    @Binding var sheet: MusicSheet?
    /// Go to artist / album. Off where the caller offers its own way there.
    var opensPages = true

    var body: some View {
        if opensPages {
            let feed = MusicFeedState.shared
            if let page = MusicFeedState.artistPage(of: track), feed.showingArtistId != track.artistId {
                Button { feed.reveal(page) } label: {
                    Label("Go to \(track.artist)", systemImage: "music.mic")
                }
            }
            if let page = MusicFeedState.albumPage(of: track), feed.showingAlbumId != track.albumId {
                Button { feed.reveal(page) } label: {
                    Label(track.albumTitle.map { "Go to \($0)" } ?? "Go to album", systemImage: "square.stack")
                }
            }
        }
        Button { sheet = .share(WavlakeLink.shareText(for: track)) } label: {
            Label("Share to Nostr", systemImage: "square.and.arrow.up")
        }
        if let hex = track.artistNpub.flatMap(MusicSheet.hex(fromNpub:)) {
            Button { sheet = .profile(hex) } label: {
                Label("\(track.artist) on Nostr", systemImage: "person.crop.circle")
            }
        }
        if let page = track.pageURL {
            Button { PlatformURL.open(page) } label: {
                Label("Open on Wavlake", systemImage: "safari")
            }
        }
    }
}

/// A Wavlake song inside a post: artwork, title, artist and a play button.
/// Shown in place of the generic link preview, so a shared song plays right
/// from the feed (and a repost or quote of it does too).
struct WavlakeTrackCard: View {
    let trackId: String
    /// The link this card replaced. The note text no longer shows it, so a
    /// track that fails to load falls back to it instead of vanishing.
    var fallbackURL: URL? = nil
    @ObservedObject private var player = MusicPlayerService.shared
    @State private var track: WavlakeTrack?
    @State private var failed = false

    /// Songs already looked up, so scrolling past a card doesn't refetch it.
    @MainActor private static var cache: [String: WavlakeTrack] = [:]

    var body: some View {
        Group {
            if let track {
                card(track)
            } else if failed {
                if let fallbackURL {
                    LinkFallbackCard(url: fallbackURL)
                }
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.secondary.opacity(0.1))
                    .frame(height: 68)
            }
        }
        .task(id: trackId) { await load() }
    }

    private func card(_ track: WavlakeTrack) -> some View {
        let isCurrent = player.current?.id == track.id
        return HStack(spacing: 12) {
            MusicArtwork(url: track.artworkURL, size: 52)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).font(.appSystem(size: 15, weight: .semibold)).lineLimit(1)
                Text(track.artist).font(.appSystem(size: 13)).foregroundColor(.secondary).lineLimit(1)
                Label("Wavlake", systemImage: "music.note")
                    .font(.appSystem(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 8)
            Button {
                if isCurrent { player.togglePlayPause() } else { player.play([track]) }
            } label: {
                Image(systemName: isCurrent && player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.appSystem(size: 38))
                    .foregroundColor(.havenPurple)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isCurrent && player.isPlaying ? "Pause \(track.title)" : "Play \(track.title)")
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.1)))
    }

    private func load() async {
        if let cached = Self.cache[trackId] { track = cached; return }
        if let found = try? await WavlakeAPI.track(trackId) {
            Self.cache[trackId] = found
            track = found
        } else {
            failed = true
        }
    }
}
