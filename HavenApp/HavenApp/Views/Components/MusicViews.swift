import SwiftUI

// MARK: - Music feed

/// The Music feed: Wavlake's trending tracks, and search across tracks,
/// albums and artists. Tapping a track plays it and queues the rest of the
/// list after it; the mini player keeps going while you browse.
struct MusicBrowserView: View {
    @ObservedObject private var player = MusicPlayerService.shared
    @State private var query = ""
    @State private var trending: [WavlakeTrack] = []
    @State private var results: [WavlakeSearchResult] = []
    /// An album or artist opened from search: its title and tracks.
    @State private var opened: (title: String, tracks: [WavlakeTrack])?
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            searchField

            if let opened {
                header(opened.title) {
                    Button { self.opened = nil } label: {
                        Label("Back", systemImage: "chevron.left").font(.appSystem(size: 14, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.havenPurple)
                }
                trackList(opened.tracks)
            } else if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                searchResults
            } else {
                header("Trending on Wavlake") { EmptyView() }
                trackList(trending)
            }

            if isLoading {
                ProgressView().tint(.havenPurple).frame(maxWidth: .infinity).padding(.vertical, 30)
            } else if let errorText {
                Text(errorText)
                    .font(.appSystem(size: 14))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if query.isEmpty && opened == nil { Task { await loadTrending() } }
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
        .task { if trending.isEmpty { await loadTrending() } }
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
                    .onTapGesture {
                        if player.current?.id == track.id {
                            player.togglePlayPause()
                        } else {
                            player.play(tracks, startAt: offset)
                        }
                    }
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
            collectionTile(title: name, subtitle: "Artist", art: art, round: true) { await open(title: name) { try await WavlakeAPI.artistTracks(id) } }
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

    private func loadTrending() async {
        isLoading = true
        errorText = nil
        do {
            trending = try await WavlakeAPI.trending()
            if trending.isEmpty { errorText = "Nothing trending right now." }
        } catch {
            errorText = "Couldn't reach Wavlake. Tap to try again."
        }
        isLoading = false
    }

    /// Searches once typing pauses, so each keystroke isn't a request.
    private func scheduleSearch() {
        searchTask?.cancel()
        opened = nil
        let term = query.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { results = []; errorText = nil; return }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            isLoading = true
            errorText = nil
            let found = (try? await WavlakeAPI.search(term)) ?? []
            guard !Task.isCancelled else { return }
            results = found
            isLoading = false
            if found.isEmpty { errorText = "No music found for \"\(term)\"." }
        }
    }

    private func open(title: String, load: () async throws -> [WavlakeTrack]) async {
        isLoading = true
        errorText = nil
        let tracks = (try? await load()) ?? []
        isLoading = false
        if tracks.isEmpty {
            errorText = "Couldn't load \(title)."
        } else {
            opened = (title, tracks)
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
                    Image(systemName: isPlaying ? "waveform" : "pause.fill")
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
    @State private var showingFull = false

    var body: some View {
        if let track = player.current {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    MusicArtwork(url: track.artworkURL, size: 38)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(track.title).font(.appSystem(size: 14, weight: .semibold)).lineLimit(1)
                        Text(track.artist).font(.appSystem(size: 12)).foregroundColor(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if player.isBuffering && player.isPlaying {
                        ProgressView().controlSize(.small).frame(width: 34, height: 34)
                    } else {
                        Button(action: player.togglePlayPause) {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.appSystem(size: 18, weight: .bold))
                                .frame(width: 34, height: 34)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                    }
                    Button(action: player.next) {
                        Image(systemName: "forward.fill")
                            .font(.appSystem(size: 15, weight: .bold))
                            .frame(width: 30, height: 34)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!player.hasNext)
                    .opacity(player.hasNext ? 1 : 0.35)
                    .accessibilityLabel("Next song")
                    Button(action: player.stop) {
                        Image(systemName: "xmark")
                            .font(.appSystem(size: 13, weight: .bold))
                            .foregroundColor(.secondary)
                            .frame(width: 26, height: 34)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop music")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)

                GeometryReader { geo in
                    Capsule()
                        .fill(Color.havenPurple)
                        .frame(width: player.duration > 0 ? geo.size.width * min(1, player.elapsed / player.duration) : 0)
                }
                .frame(height: 2)
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
            }
            .foregroundColor(.primary)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
            .onTapGesture { showingFull = true }
            .sheet(isPresented: $showingFull) { NowPlayingView() }
        }
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

    var body: some View {
        VStack(spacing: 22) {
            Capsule().fill(Color.secondary.opacity(0.4)).frame(width: 40, height: 5).padding(.top, 10)
            if let track = player.current {
                MusicArtwork(url: track.artworkURL, size: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
                VStack(spacing: 4) {
                    Text(track.title).font(.appSystem(size: 22, weight: .bold)).multilineTextAlignment(.center)
                    Text(track.artist).font(.appSystem(size: 16)).foregroundColor(.secondary)
                }
                .padding(.horizontal, 24)

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

                HStack(spacing: 44) {
                    Button(action: player.previous) {
                        Image(systemName: "backward.fill").font(.appSystem(size: 26))
                    }
                    Button(action: player.togglePlayPause) {
                        Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.appSystem(size: 64))
                            .foregroundColor(.havenPurple)
                    }
                    Button(action: player.next) {
                        Image(systemName: "forward.fill").font(.appSystem(size: 26))
                    }
                    .disabled(!player.hasNext)
                    .opacity(player.hasNext ? 1 : 0.35)
                }
                .buttonStyle(.plain)

                if let page = track.pageURL {
                    Link("Open on Wavlake", destination: page)
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
    }
}
