import AVKit
import Combine
import SwiftUI

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
