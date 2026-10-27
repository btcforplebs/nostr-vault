import SwiftUI
import AVKit
import AVFoundation

// MARK: - FullScreenVideoPlayer

/// Chromeless full-screen video player for use in FeedMediaViewer.
/// Auto-plays unmuted with looping. Shows an auto-hiding control rail
/// (play/pause, time, scrubber, mute, PiP); mirror/close overlays are
/// provided by FeedMediaViewer.
struct FullScreenVideoPlayer: View {
    let url: URL
    var mimeType: String? = nil
    /// Called when PiP takes over so the presenting viewer can dismiss itself.
    var onPiPStart: (() -> Void)? = nil
    /// Someone else's player to show — the mini player's, for a live stream
    /// popped out of it. Its sound and audio session stay theirs: nothing is
    /// started, muted or handed back here, and PiP stays off.
    var sharedPlayer: AVPlayer? = nil
    /// Play on a shared player, which its owner rejoins the broadcast for.
    var onSharedResume: (() -> Void)? = nil

    @State private var player: AVPlayer?
    @ObservedObject private var failures = VideoPlaybackFailures.shared
    @State private var showControls: Bool = true
    @State private var hideControlsWork: DispatchWorkItem? = nil
    /// The URL failed: the note author's vault on the mesh is asked instead.
    /// The gallery passes its note down; the feed's viewer leaves it at the tap.
    @Environment(\.meshMediaNote) private var envNote
    @State private var tappedNote = MeshMediaTap.note
    @State private var meshPhase: MeshMediaPhase = .loading
    @State private var meshFile: URL? = nil
    #if os(iOS)
    @ObservedObject private var pipManager = PiPManager.shared
    #endif

    var body: some View {
        ZStack {
            Color.black

            if failures.hasFailed(url) && meshFile == nil && meshPhase == .meshLookup {
                MeshMediaStatusView(phase: meshPhase, video: true, onDark: true)
            } else if failures.hasFailed(url) && meshFile == nil {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.appSystem(size: 40))
                        .foregroundColor(.orange)
                    Text(meshPhase.text(video: true) ?? "Failed to load video")
                        .font(.appHeadline)
                        .foregroundColor(.white)
                }
            } else if let player = player {
                InlinePlayerLayer(player: player, videoGravity: .resizeAspect, onLayerReady: { layer in
                    #if os(iOS)
                    if sharedPlayer == nil { PiPManager.shared.attach(layer: layer, url: url) }
                    #endif
                }, keepsPlayingInBackground: sharedPlayer != nil)
                .allowsHitTesting(false)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().tint(.white)
            }

            if let player = player, showControls {
                VStack {
                    Spacer()
                    VideoControlBar(player: player, onPiP: pipAction, onInteract: scheduleAutoHide,
                                    onResumeLive: sharedPlayer != nil ? onSharedResume : isLive ? { rejoinLive() } : nil)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                        .background(alignment: .bottom) {
                            LinearGradient(
                                colors: [.black.opacity(0), .black.opacity(0.55)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .frame(height: 130)
                            .allowsHitTesting(false)
                        }
                }
                .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .task(id: failures.hasFailed(url)) { await rescueOverMesh() }
        .onTapGesture {
            withAnimation(Motion.fade) {
                showControls.toggle()
            }
            if showControls { scheduleAutoHide() }
        }
        .onAppear {
            if let sharedPlayer {
                player = sharedPlayer
                scheduleAutoHide()
                return
            }
            #if os(iOS)
            // Opening a new video full-screen takes over from any running PiP
            if PiPManager.shared.isPiPActive && PiPManager.shared.activeURL != url {
                PiPManager.shared.stop()
            }
            #endif
            VideoPlayerCache.shared.activeFullScreenURL = url
            #if os(iOS)
            PiPManager.shared.onPiPWillStart = { onPiPStart?() }
            #endif
            setupPlayer()
            scheduleAutoHide()
        }
        #if os(iOS)
        // Back from another app: a live stream on screen carries on with the
        // broadcast. Left alone it sat paused behind the live window, and Play
        // did nothing (Logen, 2026-10-04: after watching video in another app).
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            guard isLive, sharedPlayer == nil, let player, player.timeControlStatus != .playing,
                  VideoPlayerCache.shared.activeFullScreenURL == url else { return }
            rejoinLive()
        }
        #endif
        .onDisappear {
            hideControlsWork?.cancel()
            hideControlsWork = nil
            if sharedPlayer != nil {
                // Muted here, the mini player would carry on silent.
                player?.isMuted = false
                player = nil
                return
            }
            #if os(iOS)
            if PiPManager.shared.isPiPActive && PiPManager.shared.activeURL == url {
                // PiP owns playback now — leave the player, audio session, and
                // activeFullScreenURL to PiPManager's teardown when PiP ends.
                player = nil
                return
            }
            PiPManager.shared.detach(url: url)
            PiPManager.shared.onPiPWillStart = nil
            #endif
            VideoPlayerCache.shared.activeFullScreenURL = nil
            // Restore standard inline muted play
            player?.isMuted = true
            player = nil
            // Restore audio session to allow mixing with background music
            AudioSessionManager.shared.enableMixingWithOthers()
        }
    }

    private var isLive: Bool { url.pathExtension.lowercased() == "m3u8" }

    private func rejoinLive() {
        guard let player else { return }
        VideoPlaybackService.shared.rejoinLive(player, sourceURL: url)
    }

    /// Non-nil only when PiP can actually start right now.
    private var pipAction: (() -> Void)? {
        #if os(iOS)
        guard sharedPlayer == nil, pipManager.isPiPPossible else { return nil }
        return { PiPManager.shared.start() }
        #else
        return nil
        #endif
    }

    private func scheduleAutoHide() {
        hideControlsWork?.cancel()
        let work = DispatchWorkItem {
            guard player?.timeControlStatus == .playing else { return }
            withAnimation(Motion.fade) {
                showControls = false
            }
        }
        hideControlsWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: work)
    }

    /// The URL's ladder ran out: read the video from the note author's vault
    /// on the mesh, then play that file.
    private func rescueOverMesh() async {
        let note = envNote ?? tappedNote
        guard sharedPlayer == nil, failures.hasFailed(url), meshFile == nil, note != nil else { return }
        let file = await MediaCacheService.shared.meshVideoFile(url: url, note: note, onLookup: { meshPhase = .meshLookup })
        guard let file else {
            meshPhase = .failed(after: meshPhase, meshOnly: MediaCacheService.isMeshOnly(url))
            return
        }
        meshFile = file
        let meshPlayer = await VideoPlaybackService.shared.preparedPlayer(for: file, mimeHint: mimeType, intent: .fullScreen)
        player = meshPlayer
        meshPlayer.play()
    }

    private func setupPlayer() {
        Task { @MainActor in
            // The service resolves source + MIME, applies full-screen (unmuted,
            // audio takeover) policy, and recovers from item failures internally.
            let cachedPlayer = await VideoPlaybackService.shared.preparedPlayer(
                for: url, mimeHint: mimeType, intent: .fullScreen
            )
            self.player = cachedPlayer
            cachedPlayer.play()
        }
    }
}
