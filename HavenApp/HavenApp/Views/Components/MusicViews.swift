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

    @Published var scope: Scope = .trending
    @Published var trendingWindow: TrendingWindow = .week
    /// Artists you've played or opened, newest first.
    @Published private(set) var recentArtists: [WavlakeArtist] = []

    private static let recentKey = "music.recentArtists"
    private static let maxRecent = 20
    /// Artist pages fetched this launch, for their Nostr keys. A missing
    /// key is cached too (npub nil), so Following doesn't ask twice.
    private var artistCache: [String: WavlakeArtist] = [:]
    private var cancellables = Set<AnyCancellable>()

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
    /// An album opened from search: its title and tracks.
    @State private var opened: (title: String, tracks: [WavlakeTrack])?
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var searchTask: Task<Void, Never>?
    /// Search and albums keep their own spinner and message, so clearing a
    /// search can't stop the toolbar choice's load, or the other way round.
    @State private var isSearching = false
    @State private var searchError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            searchField

            if let opened {
                header(opened.title) {
                    backButton { self.opened = nil }
                }
                trackList(opened.tracks)
            } else if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                searchResults
            } else {
                scopeContent
            }

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
        .task(id: loadKey) { await load() }
        // A toolbar pick replaces whatever search or album was showing.
        .onChange(of: loadKey) { _, _ in
            query = ""
            opened = nil
        }
        .modifier(MusicSheetHost(sheet: $sheet))
    }

    /// Showing the toolbar's choice rather than search or an album.
    private var isBrowsing: Bool { query.isEmpty && opened == nil }

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
            header("Trending \(feed.trendingWindow.title.lowercased())") { EmptyView() }
            trackList(tracks)
        case .artist(let artist):
            header(artist.name) {
                backButton { feed.scope = .trending }
            }
            trackList(tracks)
        case .following:
            if !followedArtists.isEmpty {
                header("Artists you follow") { EmptyView() }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(followedArtists) { artist in
                            collectionTile(title: artist.name, subtitle: "Artist", art: artist.artUrl, round: true) {
                                feed.show(artist)
                            }
                        }
                    }
                }
            }
            if !tracks.isEmpty {
                header("Their songs") { EmptyView() }
                trackList(tracks)
            }
        }
    }

    private func backButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label("Back", systemImage: "chevron.left").font(.appSystem(size: 14, weight: .semibold))
        }
        .buttonStyle(.plain)
        .foregroundColor(.havenPurple)
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
                Button { query = ""; opened = nil } label: {
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
        HStack {
            accessory()
            Text(title).font(.appSystem(size: 18, weight: .bold))
            Spacer()
        }
        .padding(.top, 4)
    }

    private func trackList(_ tracks: [WavlakeTrack]) -> some View {
        LazyVStack(spacing: 4) {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { offset, track in
                MusicTrackRow(track: track, isCurrent: player.current?.id == track.id, isPlaying: player.isPlaying)
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
                    .contextMenu { MusicTrackActions(track: track, sheet: $sheet) }
            }
        }
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
            collectionTile(title: title, subtitle: "Album", art: art, round: false) { await open(title: title) { try await WavlakeAPI.album(id) } }
        case .artist(let id, let name, let art):
            collectionTile(title: name, subtitle: "Artist", art: art, round: true) {
                feed.show(WavlakeArtist(id: id, name: name, artUrl: art))
                query = ""
            }
        case .track:
            EmptyView()
        }
    }

    private func collectionTile(title: String, subtitle: String, art: String?, round: Bool, action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: {
            VStack(alignment: .leading, spacing: 4) {
                MusicArtwork(url: art.flatMap(URL.init(string:)), size: 110)
                    .clipShape(round ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 10)))
                Text(title).font(.appSystem(size: 13, weight: .semibold)).lineLimit(1)
                Text(subtitle).font(.appSystem(size: 11)).foregroundColor(.secondary)
            }
            .frame(width: 110, alignment: .leading)
        }
        .buttonStyle(.plain)
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
        case .artist(let artist):
            found = (try? await WavlakeAPI.artistTracks(artist.id)) ?? []
            if found.isEmpty { message = "Couldn't load \(artist.name). Tap to try again." }
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
        opened = nil
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

    private func open(title: String, load: () async throws -> [WavlakeTrack]) async {
        isSearching = true
        searchError = nil
        let tracks = (try? await load()) ?? []
        isSearching = false
        if tracks.isEmpty {
            searchError = "Couldn't load \(title)."
        } else {
            opened = (title, tracks)
        }
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

    var body: some View {
        HStack(spacing: 12) {
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

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    placeholder
                }
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
            .sheet(isPresented: $showingFull) { NowPlayingView() }
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
            .sheet(isPresented: $showingFull) { NowPlayingView() }
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

/// Full player: big artwork, scrubber, previous / play / next.
struct NowPlayingView: View {
    @ObservedObject private var player = MusicPlayerService.shared
    @Environment(\.dismiss) private var dismiss
    @State private var scrubbing: Double?
    @State private var sheet: MusicSheet?

    var body: some View {
        VStack(spacing: 22) {
            Capsule().fill(Color.secondary.opacity(0.4)).frame(width: 40, height: 5).padding(.top, 10)
            if let track = player.current {
                MusicArtwork(url: track.artworkURL, size: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
                VStack(spacing: 4) {
                    if track.isLive { LiveBadge() }
                    Text(track.title).font(.appSystem(size: 22, weight: .bold)).multilineTextAlignment(.center)
                    Text(track.artist).font(.appSystem(size: 16)).foregroundColor(.secondary)
                }
                .padding(.horizontal, 24)

                if !track.isLive {
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

                HStack(spacing: 44) {
                    Button(action: player.previous) {
                        Image(systemName: "backward.fill").font(.appSystem(size: 26))
                    }
                    .opacity(track.isLive ? 0 : 1)
                    .disabled(track.isLive)
                    Button(action: player.togglePlayPause) {
                        Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.appSystem(size: 64))
                            .foregroundColor(.havenPurple)
                    }
                    Button(action: player.next) {
                        Image(systemName: "forward.fill").font(.appSystem(size: 26))
                    }
                    .disabled(!player.hasNext)
                    .opacity(track.isLive ? 0 : (player.hasNext ? 1 : 0.35))
                }
                .buttonStyle(.plain)

                HStack(spacing: 12) {
                    if let song = track.wavlake {
                        actionButton("Share", icon: "square.and.arrow.up") {
                            sheet = .share(WavlakeLink.shareText(for: song))
                        }
                        if let hex = song.artistNpub.flatMap(MusicSheet.hex(fromNpub:)) {
                            actionButton("Artist", icon: "person.crop.circle") { sheet = .profile(hex) }
                        }
                    } else if let host = track.hostPubkey {
                        if let stream = player.liveStream {
                            actionButton("Watch", icon: "play.rectangle") { sheet = .live(stream) }
                        }
                        actionButton("Host", icon: "person.crop.circle") { sheet = .profile(host) }
                    }
                }

                if let page = track.pageURL {
                    Link(track.isLive ? "Open stream" : "Open on Wavlake", destination: page)
                        .font(.appSystem(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)
                }
            } else {
                Text("Nothing playing").foregroundColor(.secondary)
                    .onAppear { dismiss() }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 600)
        #endif
        .presentationDetents([.large])
        .modifier(MusicSheetHost(sheet: $sheet))
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
}

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

    var body: some View {
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
                EmptyView()
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
