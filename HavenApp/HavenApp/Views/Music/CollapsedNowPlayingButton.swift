import AVKit
import Combine
import SwiftUI

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
