import SwiftUI
import AVKit
import AVFoundation

#if os(iOS)
import UIKit
#endif

// MARK: - Audio Session Manager

/// Manages audio session configuration for video playback.
/// Switches between ambient (mixing with background music) and playback (taking over audio) modes.
class AudioSessionManager {
    static let shared = AudioSessionManager()

    #if os(iOS)
    private var interruptionObserver: NSObjectProtocol?

    private init() {
        // A notification sound (or a phone call, Siri, etc.) posts .began and
        // silently pauses our AVPlayer's audio. iOS doesn't resume it for us —
        // without this observer a live stream's audio just stays dead once the
        // interrupting sound finishes.
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            self?.handleInterruption(notification)
        }
    }

    private func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue),
              type == .ended else { return }

        let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
        guard AVAudioSession.InterruptionOptions(rawValue: optionsValue).contains(.shouldResume) else { return }

        guard let url = VideoPlayerCache.shared.activeFullScreenURL,
              let player = VideoPlayerCache.shared.storedPlayer(for: url) else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        player.play()
    }

    /// Configure audio session to allow background music to continue (for muted videos)
    func enableMixingWithOthers() {
        // Never tear down the playback session while PiP is running — deactivating
        // it (or dropping to .ambient) interrupts and pauses the PiP video. This is
        // hit constantly by inline feed players spinning up during scroll; PiPManager
        // restores the mixing session itself when PiP ends.
        if PiPManager.shared.isPiPActive { return }
        do {
            let audioSession = AVAudioSession.sharedInstance()
            // Already mixing: nothing to hand back, and deactivating would stop
            // whatever this app is playing right now.
            if audioSession.category == .ambient { return }
            // Deactivate the active playback session so background music can resume
            try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)

            // Set category to ambient with mixing - don't activate yet, let AVPlayer handle it
            try audioSession.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            #if DEBUG
            print("AudioSession: Configured for ambient playback (mixing with background music)")
            #endif
        } catch {
            #if DEBUG
            print("AudioSession: Failed to enable mixing: \(error)")
            #endif
        }
    }

    /// Configure audio session to take over audio (for unmuted full-screen videos)
    func enablePlayback() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            // Already in playback: only make sure it is active. Deactivating a
            // session stops every player in it — Reels warms the next video
            // with this intent while the current one is playing with sound.
            if audioSession.category == .playback && audioSession.mode == .moviePlayback {
                try audioSession.setActive(true)
                return
            }
            // Deactivate current session first to ensure clean transition
            try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)

            // Use .playback category which ignores the hardware mute switch
            // Use .moviePlayback mode for optimal video playback
            try audioSession.setCategory(.playback, mode: .moviePlayback, options: [])
            try audioSession.setActive(true)
            #if DEBUG
            print("AudioSession: Configured for playback (taking over audio, ignoring mute switch)")
            #endif
        } catch {
            #if DEBUG
            print("AudioSession: Failed to enable playback: \(error)")
            #endif
        }
    }
    #else
    // macOS doesn't need audio session management
    func enableMixingWithOthers() {}
    func enablePlayback() {}
    #endif
}

// MARK: - PiPManager

#if os(iOS)
/// Owns the `AVPictureInPictureController` for the video currently shown full-screen.
/// Lives beyond the SwiftUI view hierarchy so PiP keeps rendering after the viewer
/// is dismissed — it retains the player layer until PiP actually stops.
final class PiPManager: NSObject, ObservableObject {
    static let shared = PiPManager()

    @Published private(set) var isPiPActive = false
    @Published private(set) var isPiPPossible = false

    /// Set by the presenting viewer so it can dismiss itself when PiP takes over.
    var onPiPWillStart: (() -> Void)?

    private var controller: AVPictureInPictureController?
    private var playerLayer: AVPlayerLayer?
    private var possibleObservation: NSKeyValueObservation?
    private(set) var activeURL: URL?

    static var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    func attach(layer: AVPlayerLayer, url: URL) {
        guard Self.isSupported, !isPiPActive, playerLayer !== layer else { return }

        guard let pip = AVPictureInPictureController(playerLayer: layer) else { return }
        pip.delegate = self
        if #available(iOS 14.2, *) {
            // Swiping home while a full-screen video plays pops it into PiP automatically
            pip.canStartPictureInPictureAutomaticallyFromInline = true
        }
        controller = pip
        playerLayer = layer
        activeURL = url
        possibleObservation = pip.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] _, change in
            DispatchQueue.main.async { self?.isPiPPossible = change.newValue ?? false }
        }
    }

    /// Drops the controller when the presenting view goes away without starting PiP.
    func detach(url: URL) {
        guard !isPiPActive, activeURL == url else { return }
        teardown()
    }

    func start() { controller?.startPictureInPicture() }
    func stop() { controller?.stopPictureInPicture() }

    /// True while PiP is rendering from this layer — the hosting view must not unhook its player.
    func ownsLayer(_ layer: AVPlayerLayer) -> Bool {
        isPiPActive && playerLayer === layer
    }

    private func teardown() {
        possibleObservation?.invalidate()
        possibleObservation = nil
        controller = nil
        playerLayer = nil
        activeURL = nil
        isPiPPossible = false
    }
}

extension PiPManager: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isPiPActive = true
        onPiPWillStart?()
        onPiPWillStart = nil
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isPiPActive = false
        // PiP window closed: end playback and hand audio back to other apps.
        playerLayer?.player?.pause()
        playerLayer?.player?.isMuted = true
        // Only clear full-screen ownership if it's still ours — a new full-screen
        // video may have claimed it while stopping this PiP.
        if VideoPlayerCache.shared.activeFullScreenURL == activeURL {
            VideoPlayerCache.shared.activeFullScreenURL = nil
            AudioSessionManager.shared.enableMixingWithOthers()
        }
        teardown()
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(true)
    }
}
#endif

// MARK: - VideoPlayerCache

/// LRU storage for the app's live AVPlayers. Construction, MIME resolution,
/// failure recovery, looping, and audio policy all live in
/// `VideoPlaybackService` — this class only stores and evicts.
class VideoPlayerCache: ObservableObject {
    static let shared = VideoPlayerCache()
    private var cache: [URL: AVPlayer] = [:]
    private var accessOrder: [URL] = []
    private let limit = 3
    private let lock = NSLock()

    /// Tracks which video URL is currently being viewed full-screen so we don't pause it when the feed cell goes off-screen
    @Published var activeFullScreenURL: URL? = nil

    /// Evicts all cached players (called on memory pressure).
    func evictAll() {
        lock.lock()
        let entries = cache
        cache.removeAll()
        accessOrder.removeAll()
        lock.unlock()

        for (url, player) in entries {
            player.pause()
            VideoPlaybackService.shared.invalidateLadder(for: url)
        }
    }

    /// Returns the cached player (refreshing its LRU position), or nil.
    func storedPlayer(for url: URL) -> AVPlayer? {
        lock.lock()
        defer { lock.unlock() }
        guard let player = cache[url] else { return nil }
        if let index = accessOrder.firstIndex(of: url) {
            accessOrder.remove(at: index)
        }
        accessOrder.append(url)
        return player
    }

    /// Stores a newly built player, evicting the LRU entry when over the limit —
    /// but never the full-screen/PiP video, which must keep playing while feed
    /// cells create players underneath it.
    func store(_ player: AVPlayer, for url: URL) {
        var evicted: (URL, AVPlayer)?

        lock.lock()
        cache[url] = player
        accessOrder.removeAll { $0 == url }
        accessOrder.append(url)
        if cache.count > limit,
           let oldest = accessOrder.first(where: { $0 != activeFullScreenURL && $0 != url }) {
            accessOrder.removeAll { $0 == oldest }
            if let oldPlayer = cache.removeValue(forKey: oldest) {
                evicted = (oldest, oldPlayer)
            }
        }
        lock.unlock()

        if let (oldURL, oldPlayer) = evicted {
            oldPlayer.pause()
            VideoPlaybackService.shared.invalidateLadder(for: oldURL)
        }
    }

    /// Removes one player (its ladder is invalidated by the service).
    func removePlayer(for url: URL) {
        lock.lock()
        let player = cache.removeValue(forKey: url)
        accessOrder.removeAll { $0 == url }
        lock.unlock()
        player?.pause()
    }
}

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

// MARK: - VideoScrubber

/// Minimal seek bar — thin progress line with drag-to-seek.
struct VideoScrubber: View {
    let player: AVPlayer
    /// Fired on every drag update so a container can keep its auto-hiding controls visible.
    var onScrub: (() -> Void)? = nil

    @State private var progress: Double = 0
    @State private var isDragging: Bool = false
    @State private var timeObserver: Any?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.3))
                    .frame(height: 3)

                Capsule()
                    .fill(Color.white.opacity(0.85))
                    .frame(width: max(0, geo.size.width * progress), height: isDragging ? 5 : 3)
                    .animation(Motion.control, value: isDragging)
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        onScrub?()
                        let fraction = min(max(value.location.x / geo.size.width, 0), 1)
                        progress = fraction
                        seek(to: fraction)
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
        }
        .frame(height: 20) // generous hit target
        .onAppear { startObserving() }
        .onDisappear { stopObserving() }
    }

    private func startObserving() {
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            guard !isDragging else { return }
            guard let duration = player.currentItem?.duration,
                  duration.isValid, !duration.isIndefinite else { return }
            let total = CMTimeGetSeconds(duration)
            guard total > 0 else { return }
            progress = CMTimeGetSeconds(time) / total
        }
    }

    private func stopObserving() {
        if let observer = timeObserver {
            player.removeTimeObserver(observer)
            timeObserver = nil
        }
    }

    private func seek(to fraction: Double) {
        guard let duration = player.currentItem?.duration,
              duration.isValid, !duration.isIndefinite else { return }
        let target = CMTimeGetSeconds(duration) * fraction
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
    }
}

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

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.platformTertiaryGroupedBackground

                if failures.hasFailed(url) {
                    // Show thumbnail with play overlay on error
                    if let thumb = thumbnail {
                        Image(platformImage: thumb)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.height)
                    }
                    Image(systemName: "play.circle.fill")
                        .font(.appSystem(size: 36))
                        .foregroundColor(.white.opacity(0.85))
                        .shadow(color: .black.opacity(0.5), radius: 4)
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

// MARK: - InlinePlayerLayer (chromeless AVPlayerLayer)

#if os(macOS)
struct InlinePlayerLayer: NSViewRepresentable {
    let player: AVPlayer
    var videoGravity: AVLayerVideoGravity = .resizeAspectFill
    /// Called with the backing AVPlayerLayer once created (used to wire up PiP on iOS).
    var onLayerReady: ((AVPlayerLayer) -> Void)? = nil

    func makeNSView(context: Context) -> PlayerNSView {
        let view = PlayerNSView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = videoGravity
        onLayerReady?(view.playerLayer)
        return view
    }

    func updateNSView(_ nsView: PlayerNSView, context: Context) {
        if nsView.playerLayer.player != player {
            nsView.playerLayer.player = player
        }
        if nsView.playerLayer.videoGravity != videoGravity {
            nsView.playerLayer.videoGravity = videoGravity
        }
    }
    
    static func dismantleNSView(_ nsView: PlayerNSView, coordinator: Coordinator) {
        nsView.playerLayer.player = nil
    }
}

class PlayerNSView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.isOpaque = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.isOpaque = true
    }

    override func makeBackingLayer() -> CALayer {
        let playerLayer = AVPlayerLayer()
        playerLayer.isOpaque = true
        return playerLayer
    }
    
    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }

    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
#else
struct InlinePlayerLayer: UIViewRepresentable {
    let player: AVPlayer
    var videoGravity: AVLayerVideoGravity = .resizeAspectFill
    /// Called with the backing AVPlayerLayer once created (used to wire up PiP).
    var onLayerReady: ((AVPlayerLayer) -> Void)? = nil

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = videoGravity
        onLayerReady?(view.playerLayer)
        return view
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {
        if uiView.playerLayer.player != player {
            uiView.playerLayer.player = player
        }
        if uiView.playerLayer.videoGravity != videoGravity {
            uiView.playerLayer.videoGravity = videoGravity
        }
    }
    
    static func dismantleUIView(_ uiView: PlayerUIView, coordinator: Coordinator) {
        // PiP keeps rendering from this layer after the view leaves the hierarchy —
        // unhooking the player here would blank the PiP window.
        if PiPManager.shared.ownsLayer(uiView.playerLayer) { return }
        uiView.playerLayer.player = nil
    }

    class PlayerUIView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
#endif

// MARK: - Full VideoPlayerView (native controls, used for standalone playback)

#if os(macOS)
struct NativeVideoPlayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player != player {
            nsView.player = player
        }
    }
}
#else
struct NativeVideoPlayer: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = true
        if #available(iOS 16.0, *) {
            controller.allowsVideoFrameAnalysis = true
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        if uiViewController.player != player {
            uiViewController.player = player
        }
    }
}
#endif

// MARK: - VideoControlBar

/// Bottom control rail for the full-screen player:
/// play/pause · elapsed · scrubber · duration · mute · PiP.
struct VideoControlBar: View {
    let player: AVPlayer
    /// Non-nil shows the PiP button (iOS devices where PiP is currently possible).
    var onPiP: (() -> Void)? = nil
    /// Called on any control interaction so the container can restart its auto-hide timer.
    var onInteract: (() -> Void)? = nil

    @State private var isPlaying: Bool = true
    @State private var isMuted: Bool = false
    @State private var elapsed: Double = 0
    @State private var duration: Double = 0
    @State private var timeObserver: Any?

    var body: some View {
        HStack(spacing: 12) {
            Button {
                onInteract?()
                if isPlaying { player.pause() } else { player.play() }
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.appSystem(size: 18, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text(Self.timeString(elapsed))
                .font(.appSystem(size: 12, weight: .medium).monospacedDigit())
                .foregroundColor(.white.opacity(0.85))

            VideoScrubber(player: player, onScrub: { onInteract?() })

            Text(Self.timeString(duration))
                .font(.appSystem(size: 12, weight: .medium).monospacedDigit())
                .foregroundColor(.white.opacity(0.85))

            Button {
                onInteract?()
                isMuted.toggle()
                player.isMuted = isMuted
            } label: {
                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.appSystem(size: 15, weight: .medium))
                    .foregroundColor(.white)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let onPiP = onPiP {
                Button {
                    onPiP()
                } label: {
                    Image(systemName: "pip.enter")
                        .font(.appSystem(size: 15, weight: .medium))
                        .foregroundColor(.white)
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .onReceive(player.publisher(for: \.timeControlStatus)) { status in
            isPlaying = (status != .paused)
        }
        .onAppear {
            isMuted = player.isMuted
            startObserving()
        }
        .onDisappear { stopObserving() }
    }

    private func startObserving() {
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            elapsed = CMTimeGetSeconds(time)
            if let itemDuration = player.currentItem?.duration,
               itemDuration.isValid, !itemDuration.isIndefinite {
                duration = CMTimeGetSeconds(itemDuration)
            }
        }
    }

    private func stopObserving() {
        if let observer = timeObserver {
            player.removeTimeObserver(observer)
            timeObserver = nil
        }
    }

    static func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}

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

    @State private var player: AVPlayer?
    @ObservedObject private var failures = VideoPlaybackFailures.shared
    @State private var showControls: Bool = true
    @State private var hideControlsWork: DispatchWorkItem? = nil
    #if os(iOS)
    @ObservedObject private var pipManager = PiPManager.shared
    #endif

    var body: some View {
        ZStack {
            Color.black

            if failures.hasFailed(url) {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.appSystem(size: 40))
                        .foregroundColor(.orange)
                    Text("Failed to load video")
                        .font(.appHeadline)
                        .foregroundColor(.white)
                }
            } else if let player = player {
                InlinePlayerLayer(player: player, videoGravity: .resizeAspect, onLayerReady: { layer in
                    #if os(iOS)
                    PiPManager.shared.attach(layer: layer, url: url)
                    #endif
                })
                .allowsHitTesting(false)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().tint(.white)
            }

            if let player = player, showControls {
                VStack {
                    Spacer()
                    VideoControlBar(player: player, onPiP: pipAction, onInteract: scheduleAutoHide)
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
        .onTapGesture {
            withAnimation(Motion.fade) {
                showControls.toggle()
            }
            if showControls { scheduleAutoHide() }
        }
        .onAppear {
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
        .onDisappear {
            hideControlsWork?.cancel()
            hideControlsWork = nil
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

    /// Non-nil only when PiP can actually start right now.
    private var pipAction: (() -> Void)? {
        #if os(iOS)
        guard pipManager.isPiPPossible else { return nil }
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
