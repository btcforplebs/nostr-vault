import SwiftUI
import AVKit
import AVFoundation

#if os(iOS)
import UIKit
#endif

struct VideoPlayerView: View {
    let url: URL
    /// Optional MIME hint used when the URL has no extension (e.g. Blossom hashes).
    /// AVFoundation can't infer the container format without it, so playback fails silently.
    var mimeType: String? = nil
    @State private var player: AVPlayer?
    @ObservedObject private var failures = VideoPlaybackFailures.shared

    @State private var viewSize: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if failures.hasFailed(url) {
                    errorContent
                } else if let player = player {
                    NativeVideoPlayer(player: player)
                        .onAppear {
                            player.play()
                        }
                        .onDisappear {
                            player.pause()
                        }
                } else {
                    loadingContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(minWidth: 300, minHeight: 200) // Avoid AVPlayerView constraint warnings
            .onChange(of: geo.size) { _, newSize in
                // Strict size gate: Don't load player unless we have enough width for the controls
                if viewSize == .zero && newSize.width > 100 && newSize.height > 100 {
                    viewSize = newSize
                    setupPlayer()
                }
            }
            .onAppear {
                if geo.size.width > 100 && geo.size.height > 100 {
                    viewSize = geo.size
                    setupPlayer()
                }
            }
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }

    private var loadingContent: some View {
        VStack(spacing: 20) {
            ProgressView()
            Text("Loading video...")
                .foregroundColor(.secondary)
        }
    }

    private var errorContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.appSystem(size: 40))
                .foregroundColor(.orange)
            Text("Failed to load video")
                .font(.appHeadline)
            Text("Every source for this video failed to play.")
                .font(.appCaption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button("Try Again") { retry() }
                .buttonStyle(.bordered)
        }
    }

    /// Drops the dead player and its ladder so the next attempt rebuilds from
    /// scratch — the network (or a healed local copy) may work now.
    private func retry() {
        player?.pause()
        player = nil
        VideoPlayerCache.shared.removePlayer(for: url)
        VideoPlaybackService.shared.invalidateLadder(for: url)
        VideoPlaybackFailures.shared.clear(url)
        setupPlayer()
    }

    private func setupPlayer() {
        guard player == nil else { return }
        Task { @MainActor in
            // The service resolves MIME (HEAD + magic-byte sniff), picks the
            // source (verified local file vs remote), and recovers from item
            // failures internally — nothing to decide here.
            self.player = await VideoPlaybackService.shared.preparedPlayer(
                for: url, mimeHint: mimeType, intent: .standalone
            )
        }
    }
}
