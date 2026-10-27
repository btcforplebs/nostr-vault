import SwiftUI
import AVKit
import AVFoundation

// MARK: - VideoShimmerPlaceholder

/// Animated shimmer placeholder shown while a video thumbnail is loading.
/// Provides visual feedback that content is incoming rather than a blank grey frame.
private struct VideoShimmerPlaceholder: View {
    @State private var phase: CGFloat = -1.0

    var body: some View {
        ZStack {
            Color.platformTertiaryGroupedBackground

            // Subtle gradient shimmer sweep
            LinearGradient(
                stops: [
                    .init(color: .white.opacity(0), location: max(0, min(1, phase - 0.3))),
                    .init(color: .white.opacity(0.06), location: max(0, min(1, phase))),
                    .init(color: .white.opacity(0), location: max(0, min(1, phase + 0.3)))
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            // Centered video icon so user knows this is a video
            Image(systemName: "video.fill")
                .font(.appSystem(size: 24))
                .foregroundColor(.white.opacity(0.25))
        }
        .onAppear {
            // No sweep at all under Reduce Motion — leaving `phase` at its
            // initial value keeps a plain, static placeholder rather than one
            // frozen partway through a gradient sweep.
            guard let loop = Motion.ambientPulse else { return }
            withAnimation(loop) { phase = 2.0 }
        }
    }
}

// MARK: - InlineFeedVideoPlayer

/// Lightweight inline video player for feed cards.
/// - Auto-plays muted when visible
/// - Loops continuously
/// - Tap toggles mute (shows speaker icon briefly)
/// - Pauses when scrolled off-screen
struct InlineFeedVideoPlayer: View {
    let url: URL
    /// Called when the user taps the video body (excluding the mute button).
    var onTap: (() -> Void)? = nil
    /// Reports the video's aspect ratio (width / height) once a frame is known,
    /// so the container can size it to its natural shape.
    var onAspectRatio: ((CGFloat) -> Void)? = nil
    @ObservedObject private var cache = VideoPlayerCache.shared
    @State private var player: AVPlayer?
    @State private var isMuted: Bool = true
    @State private var isPlaying: Bool = false
    @ObservedObject private var failures = VideoPlaybackFailures.shared
    @State private var thumbnail: PlatformImage? = nil
    @State private var loopObserver: NSObjectProtocol? = nil
    @State private var isReadyToPlay: Bool = false
    @State private var deferredSetup: DispatchWorkItem? = nil
    /// The URL failed: the note author's vault on the mesh is asked instead.
    @Environment(\.meshMediaNote) private var meshNote
    @State private var meshPhase: MeshMediaPhase = .loading
    @State private var meshFile: URL? = nil

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.platformTertiaryGroupedBackground

                if failures.hasFailed(url) && meshFile == nil {
                    // Show thumbnail with play overlay on error
                    if let thumb = thumbnail {
                        Image(platformImage: thumb)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.height)
                    }
                    if meshPhase == .loading {
                        Image(systemName: "play.circle.fill")
                            .font(.appSystem(size: 36))
                            .foregroundColor(.white.opacity(0.85))
                            .shadow(color: .black.opacity(0.5), radius: 4)
                    } else {
                        MeshMediaStatusView(phase: meshPhase, video: true)
                    }
                } else if let player = player {
                    ZStack {
                        if cache.activeFullScreenURL != url {
                            InlinePlayerLayer(player: player)
                                .frame(width: geo.size.width, height: geo.size.height)
                                .allowsHitTesting(false) // Let touches fall through natively for seamless swiping and tapping!
                                .onReceive(player.publisher(for: \.timeControlStatus)) { status in
                                    if status == .playing {
                                        withAnimation(Motion.fade) {
                                            isReadyToPlay = true
                                        }
                                    }
                                }
                                .onReceive(player.publisher(for: \.status)) { status in
                                    if status == .readyToPlay {
                                        if player.rate > 0 || CMTimeGetSeconds(player.currentTime()) > 0.1 {
                                            withAnimation(Motion.fade) {
                                                isReadyToPlay = true
                                            }
                                        }
                                    }
                                }
                        } else {
                            // Detached for full-screen: render static thumbnail
                            if let thumb = thumbnail {
                                Image(platformImage: thumb)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: geo.size.width, height: geo.size.height)
                            }
                        }

                        // Seamless thumbnail overlay that fades out once player starts rendering
                        if !isReadyToPlay && cache.activeFullScreenURL != url, let thumb = thumbnail {
                            Image(platformImage: thumb)
                                .resizable()
                                .scaledToFill()
                                .frame(width: geo.size.width, height: geo.size.height)
                                .transition(.opacity)
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .contentShape(Rectangle())
                    .onTapGesture { onTap?() }
                    // The player knows the shape (rotation applied) as soon as
                    // it can play; the frame grab may wait on a full download.
                    .onReceive(player.publisher(for: \.currentItem?.presentationSize)) { size in
                        if let size, let ratio = FeedVideoShape.ratio(of: size) { onAspectRatio?(ratio) }
                    }
                } else {
                    // Loading — show thumbnail if ready, otherwise shimmer placeholder
                    if let thumb = thumbnail {
                        Image(platformImage: thumb)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.height)
                    } else {
                        VideoShimmerPlaceholder()
                    }
                }

                // Bottom controls: mute button + scrubber
                VStack(spacing: 0) {
                    Spacer()
                    HStack {
                        Spacer()
                        Button(action: toggleMute) {
                            Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                .font(.appSystem(size: 14, weight: .medium))
                                .foregroundColor(.white)
                                .padding(8)
                                .background(Circle().fill(Color.black.opacity(0.6)))
                        }
                        .buttonStyle(.plain)
                        .padding(8)
                    }
                    if let player = player {
                        VideoScrubber(player: player)
                            .padding(.horizontal, 4)
                            .padding(.bottom, 4)
                    }
                }
            }
            .clipped()
            .task(id: failures.hasFailed(url)) { await rescueOverMesh() }
            .onAppear {
                if geo.size.width > 50 {
                    if player == nil {
                        loadThumbnail()
                        // Defer player setup by 300ms so fast-scrolling
                        // never triggers AVPlayer creation
                        let work = DispatchWorkItem { [self] in
                            if self.player == nil {
                                self.setupPlayer()
                            }
                        }
                        deferredSetup = work
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
                    } else if let player {
                        VideoPlaybackService.shared.setMuted(isMuted, on: player)
                        player.play()
                        isPlaying = true
                    }
                }
            }
            .onDisappear {
                deferredSetup?.cancel()
                deferredSetup = nil
                if VideoPlayerCache.shared.activeFullScreenURL != url {
                    player?.pause()
                    isPlaying = false
                    isReadyToPlay = false
                    // Restore mixing mode when video leaves screen (in case it was unmuted)
                    if !isMuted {
                        if let player {
                            VideoPlaybackService.shared.setMuted(true, on: player)
                        }
                        isMuted = true
                    }
                }
            }
        }
    }

    private func toggleMute() {
        isMuted.toggle()
        if let player {
            VideoPlaybackService.shared.setMuted(isMuted, on: player)
        }
    }

    private func loadThumbnail() {
        Task {
            if let thumb = await MediaCacheService.shared.generateThumbnail(for: url) {
                await MainActor.run {
                    withAnimation(Motion.fade) {
                        self.thumbnail = thumb
                    }
                    let size = thumb.size
                    if size.width > 0, size.height > 0 {
                        onAspectRatio?(size.width / size.height)
                    }
                }
            }
        }
    }

    /// The URL's ladder ran out: read the video from the note author's vault
    /// on the mesh, then play that file.
    private func rescueOverMesh() async {
        guard failures.hasFailed(url), meshFile == nil, meshNote != nil else { return }
        meshPhase = .loading
        let file = await MediaCacheService.shared.meshVideoFile(url: url, note: meshNote, onLookup: { meshPhase = .meshLookup })
        guard let file else {
            meshPhase = .failed(after: meshPhase, meshOnly: MediaCacheService.isMeshOnly(url))
            return
        }
        meshFile = file
        let meshPlayer = await VideoPlaybackService.shared.preparedPlayer(for: file, intent: .inline)
        meshPlayer.isMuted = isMuted
        player?.pause()
        player = meshPlayer
        meshPlayer.play()
        isPlaying = true
    }

    private func setupPlayer() {
        Task { @MainActor in
            // The service resolves source + MIME, applies inline (muted, mixing)
            // policy, and recovers from item failures internally.
            let cachedPlayer = await VideoPlaybackService.shared.preparedPlayer(for: url, intent: .inline)
            cachedPlayer.isMuted = isMuted
            self.player = cachedPlayer
            cachedPlayer.play()
            isPlaying = true
        }
    }
}
