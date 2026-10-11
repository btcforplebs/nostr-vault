import AVKit
import Combine
import SwiftUI

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
