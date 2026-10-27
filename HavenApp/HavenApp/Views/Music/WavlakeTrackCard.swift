import AVKit
import Combine
import SwiftUI

/// A Wavlake song inside a post: artwork, title, artist and a play button.
/// Shown in place of the generic link preview, so a shared song plays right
/// from the feed (and a repost or quote of it does too). Tapping the song
/// opens its artist's page in Music, scrolled to it.
struct WavlakeTrackCard: View {
    let trackId: String
    /// The link this card replaced. The note text no longer shows it, so a
    /// track that fails to load falls back to it instead of vanishing.
    var fallbackURL: URL? = nil
    @ObservedObject private var player = MusicPlayerService.shared
    #if os(iOS)
    /// Closes the sheet the card is in (a thread), so the Music page isn't
    /// opened underneath it.
    @Environment(\.dismiss) private var dismiss
    #endif
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
            // The song itself opens its artist's page in Music, scrolled to
            // this song; the play button plays it right here.
            if let page = MusicFeedState.artistPage(of: track) {
                Button { open(page, for: track) } label: {
                    info(track).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(track.title) by \(track.artist)")
                .accessibilityHint("Opens \(track.artist) in Music")
            } else {
                info(track)
            }
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

    /// As the full player's Go to: the sheet goes first, then the page
    /// opens, so the switch to the feed tab doesn't happen under it.
    private func open(_ page: MusicFeedState.Page, for track: WavlakeTrack) {
        MusicSongHighlight.shared.show(track)
        #if os(iOS)
        dismiss()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            MusicFeedState.shared.reveal(page)
        }
        #else
        MusicFeedState.shared.reveal(page)
        #endif
    }

    private func info(_ track: WavlakeTrack) -> some View {
        HStack(spacing: 12) {
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
        }
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
