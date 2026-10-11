import AVKit
import Combine
import SwiftUI

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
