import AVKit
import Combine
import SwiftUI

/// The Music feed: Wavlake's trending tracks, and search across tracks,
/// albums and artists. Tapping a track plays it and queues the rest of the
/// list after it; the mini player keeps going while you browse.
struct MusicBrowserView: View {
    @ObservedObject private var player = MusicPlayerService.shared
    @ObservedObject private var feed = MusicFeedState.shared
    /// Watched so blocking an artist clears their music as you block.
    @ObservedObject private var config = ConfigService.shared
    @State private var sheet: MusicSheet?
    @State private var query = ""
    @State private var results: [WavlakeSearchResult] = []
    @State private var isLoading = false
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
        .task(id: feed.listingKey) { await load() }
        // A toolbar pick replaces whatever search was showing.
        .onChange(of: feed.picks) { _, _ in query = "" }
        .modifier(MusicSheetHost(sheet: $sheet))
    }

    private static let topAnchor = "music.top"

    // MARK: - Blocked artists

    private var blockedKeys: Set<String> { config.activeAccountBlockedHexPubkeys }
    private var blockedArtistIds: Set<String> { feed.blockedArtistIds }

    private func visible(_ tracks: [WavlakeTrack]) -> [WavlakeTrack] {
        WavlakeBlockFilter.tracks(tracks, blocked: blockedKeys, artistIds: blockedArtistIds,
                                 hex: MusicSheet.hex(fromNpub:))
    }

    private func visible(_ artists: [WavlakeArtist]) -> [WavlakeArtist] {
        WavlakeBlockFilter.artists(artists, blocked: blockedKeys, artistIds: blockedArtistIds,
                                   hex: MusicSheet.hex(fromNpub:))
    }

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
        // A kept listing stays up while it refreshes, without a spinner.
        if isBrowsing ? isLoading && listing.isEmpty : isSearching {
            ProgressView().tint(.havenPurple).frame(maxWidth: .infinity).padding(.vertical, 30)
        } else if let message = isBrowsing ? listing.message : searchError {
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

    /// What the toolbar's current choice shows, kept between opens.
    private var listing: MusicFeedState.Listing { feed.listings[feed.listingKey] ?? .init() }

    /// The songs for the toolbar's current choice.
    private var tracks: [WavlakeTrack] { listing.tracks }

    @ViewBuilder
    private var scopeContent: some View {
        switch feed.scope {
        case .trending:
            let window = feed.trendingWindow.title.lowercased()
            let recents = visible(feed.recentArtists)
            if !recents.isEmpty {
                header("Your artists") { EmptyView() }
                artistRow(recents)
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
            trackList(visible(tracks))
        case .artist(let artist):
            MusicArtistPage(artist: artist, sheet: $sheet) { feed.scope = .trending }
                .id(artist.id)
        case .following:
            let artists = visible(listing.artists)
            let songs = visible(tracks)
            if !artists.isEmpty {
                header("Artists you follow") { EmptyView() }
                artistRow(artists)
            }
            if !songs.isEmpty {
                header("Their songs") { EmptyView() }
                trackList(songs)
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
        return visible(tracks).compactMap { track -> WavlakeArtist? in
            guard let id = track.artistId, seen.insert(id).inserted else { return nil }
            return WavlakeArtist(id: id, name: track.artist, artUrl: track.artistArtUrl, npub: track.artistNpub)
        }
        .prefix(Self.rowLimit).map { $0 }
    }

    private var trendingAlbums: [WavlakeAlbum] {
        var seen = Set<String>()
        return visible(tracks).compactMap { track -> WavlakeAlbum? in
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
        let shown = WavlakeBlockFilter.results(results, blocked: blockedKeys,
                                               artistIds: blockedArtistIds,
                                               hex: MusicSheet.hex(fromNpub:))
        let tracks = shown.compactMap { if case .track(let t) = $0 { return t } else { return nil } }
        let collections = shown.filter { if case .track = $0 { return false } else { return true } }
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
        isLoading = true
        await feed.loadListing()
        // A newer choice took over while this one loaded; it owns the spinner.
        guard !Task.isCancelled else { return }
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
