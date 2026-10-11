import AVKit
import Combine
import SwiftUI

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
                    // A live stream shows its own picture, moving, over the
                    // stream's image (which stays as the fallback while it loads).
                    .overlay {
                        if let live = player.livePlayer {
                            InlinePlayerLayer(player: live, videoGravity: .resizeAspectFill,
                                              keepsPlayingInBackground: true)
                                .allowsHitTesting(false)
                        }
                    }
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
