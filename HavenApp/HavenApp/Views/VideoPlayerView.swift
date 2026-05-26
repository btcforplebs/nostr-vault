import SwiftUI
import AVKit
import AVFoundation

// MARK: - VideoPlayerCache

class VideoPlayerCache: ObservableObject {
    static let shared = VideoPlayerCache()
    private var cache: [URL: AVPlayer] = [:]
    private var observers: [URL: NSObjectProtocol] = [:]
    private var accessOrder: [URL] = []
    private let limit = 10
    private let lock = NSLock()
    
    /// Tracks which video URL is currently being viewed full-screen so we don't pause it when the feed cell goes off-screen
    @Published var activeFullScreenURL: URL? = nil

    func player(for url: URL) -> AVPlayer {
        lock.lock()
        defer { lock.unlock() }

        // Update LRU access order
        if let index = accessOrder.firstIndex(of: url) {
            accessOrder.remove(at: index)
        }
        accessOrder.append(url)

        if let existing = cache[url] {
            // Evict broken players so they get recreated with (potentially now-correct) MIME info
            if existing.currentItem?.status != .failed && existing.currentItem?.error == nil {
                return existing
            }
            #if DEBUG
            print("VideoPlayerCache: Evicting failed player for \(url.lastPathComponent)")
            #endif
            existing.pause()
            if let obs = observers.removeValue(forKey: url) {
                NotificationCenter.default.removeObserver(obs)
            }
            cache.removeValue(forKey: url)
        }

        let finalURL = MediaCacheService.shared.preparePlayableURL(for: url) ?? url

        var assetOptions: [String: Any] = [:]
        if finalURL.pathExtension.isEmpty {
            let mimeType = MediaTypeDetector.shared.getCachedContentType(for: url) ?? "video/mp4"
            assetOptions[AVURLAssetOverrideMIMETypeKey] = mimeType
        }

        let asset = AVURLAsset(url: finalURL, options: assetOptions)
        let playerItem = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: playerItem)
        player.isMuted = true
        
        // Auto-looping logic
        let observer = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak player] _ in
            player?.seek(to: .zero)
            player?.play()
        }

        cache[url] = player
        observers[url] = observer

        // Evict oldest if limit exceeded
        if cache.count > limit {
            if let oldest = accessOrder.first {
                accessOrder.removeFirst()
                if let oldPlayer = cache.removeValue(forKey: oldest) {
                    oldPlayer.pause()
                }
                if let oldObserver = observers.removeValue(forKey: oldest) {
                    NotificationCenter.default.removeObserver(oldObserver)
                }
            }
        }

        return player
    }
}

struct VideoPlayerView: View {
    let url: URL
    /// Optional MIME hint used when the URL has no extension (e.g. Blossom hashes).
    /// AVFoundation can't infer the container format without it, so playback fails silently.
    var mimeType: String? = nil
    @State private var player: AVPlayer?
    @State private var loadError: String? = nil

    @State private var viewSize: CGSize = .zero
    
    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let _ = loadError {
                    // ... error view ...
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
    
    private var errorContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundColor(.orange)
            Text("Failed to load video")
                .font(.headline)
            Text(loadError ?? "Unknown error")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            
            Button("Try Again") {
                loadError = nil
                setupPlayer()
            }
            .buttonStyle(.bordered)
        }
    }
    
    private var loadingContent: some View {
        VStack(spacing: 20) {
            ProgressView()
            Text("Loading video...")
                .foregroundColor(.secondary)
        }
    }
    
    private func setupPlayer() {
        // Use the new helper to get a guaranteed playable URL (with extension)
        let finalURL = MediaCacheService.shared.preparePlayableURL(for: url) ?? url
        
        // Safety check for local files
        if finalURL.isFileURL {
            // Start by checking the file at the path (resolving symlinks if needed)
            let actualPath = finalURL.resolvingSymlinksInPath().path
            
            if !FileManager.default.fileExists(atPath: actualPath) {
                #if DEBUG
                print("VideoPlayerView: Local file missing at \(actualPath)")
                #endif
                loadError = "Local file not found."
                return
            }
            
            if let attr = try? FileManager.default.attributesOfItem(atPath: actualPath),
               let size = attr[.size] as? UInt64, size < 200 {
                #if DEBUG
                print("VideoPlayerView: File too small (\(size) bytes)")
                #endif
                loadError = "Video file is invalid or too small."
                return
            }
        }
        
        // Strict Constraint Safety: 
        // AVPlayerViewController (AppKit backend) throws constraint exceptions if initialized 
        // with near-zero frames. We must ensure we are ready.
        if viewSize.width < 100 || viewSize.height < 100 {
            #if DEBUG
            print("VideoPlayerView: Skipping setup - view too small (\(viewSize))")
            #endif
            return
        }
        
        #if DEBUG
        print("VideoPlayerView: Setting up player for \(finalURL.lastPathComponent)")
        #endif
        
        // For extensionless remote URLs (e.g. Blossom hashes), AVFoundation can't infer the
        // content type from the URL alone. We must provide an explicit MIME type hint via
        // AVURLAssetOverrideMIMETypeKey so AVPlayer knows how to demux the stream.
        var assetOptions: [String: Any] = [:]
        if finalURL.pathExtension.isEmpty {
            // Prefer caller-supplied mime, then the detector cache, fall back to video/mp4
            let resolved = mimeType
                ?? MediaTypeDetector.shared.getCachedContentType(for: url)
                ?? "video/mp4"
            assetOptions[AVURLAssetOverrideMIMETypeKey] = resolved
            #if DEBUG
            print("VideoPlayerView: Using MIME override '\(resolved)' for extensionless URL")
            #endif
        }
        
        let asset = AVURLAsset(url: finalURL, options: assetOptions)
        let playerItem = AVPlayerItem(asset: asset)
        
        // Initialize immediately - removing the async delay which caused race conditions
        let newPlayer = AVPlayer(playerItem: playerItem)
        self.player = newPlayer
        
        // Watch for failures
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { _ in }
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
    @ObservedObject private var cache = VideoPlayerCache.shared
    @State private var player: AVPlayer?
    @State private var isMuted: Bool = true
    @State private var isPlaying: Bool = false
    @State private var loadError: String? = nil
    @State private var thumbnail: PlatformImage? = nil
    @State private var loopObserver: NSObjectProtocol? = nil
    @State private var isReadyToPlay: Bool = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.platformTertiaryGroupedBackground

                if let _ = loadError {
                    // Show thumbnail with play overlay on error
                    if let thumb = thumbnail {
                        Image(platformImage: thumb)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.height)
                    }
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 36))
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
                                        withAnimation(.easeOut(duration: 0.3)) {
                                            isReadyToPlay = true
                                        }
                                    }
                                }
                                .onReceive(player.publisher(for: \.status)) { status in
                                    if status == .readyToPlay {
                                        if player.rate > 0 || CMTimeGetSeconds(player.currentTime()) > 0.1 {
                                            withAnimation(.easeOut(duration: 0.3)) {
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
                    // Loading — show thumbnail or progress
                    if let thumb = thumbnail {
                        Image(platformImage: thumb)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.height)
                    }
                    ProgressView()
                        .tint(.white.opacity(0.8))
                }

                // Persistent Mute/Unmute button in bottom right
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button(action: toggleMute) {
                            Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.white)
                                .padding(8)
                                .background(Circle().fill(Color.black.opacity(0.6)))
                        }
                        .buttonStyle(.plain)
                        .padding(8)
                    }
                }
            }
            .clipped()
            .onAppear {
                if geo.size.width > 50 {
                    if player == nil {
                        loadThumbnail()
                        setupPlayer()
                    } else {
                        player?.play()
                        isPlaying = true
                    }
                }
            }
            .onDisappear {
                if VideoPlayerCache.shared.activeFullScreenURL != url {
                    player?.pause()
                    isPlaying = false
                    isReadyToPlay = false
                }
            }
        }
    }

    private func toggleMute() {
        isMuted.toggle()
        player?.isMuted = isMuted
    }

    private func loadThumbnail() {
        Task {
            if let thumb = await MediaCacheService.shared.generateThumbnail(for: url) {
                await MainActor.run { self.thumbnail = thumb }
            }
        }
    }

    private func setupPlayer() {
        let cachedPlayer = VideoPlayerCache.shared.player(for: url)
        cachedPlayer.isMuted = isMuted
        self.player = cachedPlayer
        cachedPlayer.play()
        isPlaying = true
    }
}

// MARK: - InlinePlayerLayer (chromeless AVPlayerLayer)

#if os(macOS)
struct InlinePlayerLayer: NSViewRepresentable {
    let player: AVPlayer
    var videoGravity: AVLayerVideoGravity = .resizeAspectFill

    func makeNSView(context: Context) -> PlayerNSView {
        let view = PlayerNSView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = videoGravity
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

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = videoGravity
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

// MARK: - FullScreenVideoPlayer

/// Chromeless full-screen video player for use in FeedMediaViewer.
/// Matches the visual language of InlineFeedVideoPlayer but unmuted, with tap-to-pause, custom scrubber, and iPad optimizations.
struct FullScreenVideoPlayer: View {
    let url: URL
    var mimeType: String? = nil

    @State private var player: AVPlayer?
    @State private var isMuted: Bool = false
    @State private var isPlaying: Bool = true
    @State private var showPlayIcon: Bool = false
    @State private var loadError: String? = nil
    
    // Scrubber / playback tracking
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var isScrubbing: Bool = false
    @State private var timeObserverToken: Any? = nil

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    private var isPadOrMac: Bool {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .pad || horizontalSizeClass == .regular
        #else
        return true
        #endif
    }

    var body: some View {
        ZStack {
            Color.black

            if let _ = loadError {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.orange)
                    Text("Failed to load video")
                        .font(.headline)
                        .foregroundColor(.white)
                }
            } else if let player = player {
                InlinePlayerLayer(player: player, videoGravity: .resizeAspect)
                    .allowsHitTesting(false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                
                Color.clear
                    .contentShape(Rectangle())
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onTapGesture { togglePlayPause() }

                // Momentary play/pause feedback icon
                if showPlayIcon {
                    Image(systemName: isPlaying ? "play.fill" : "pause.fill")
                        .font(.system(size: 44, weight: .bold))
                        .foregroundColor(.white.opacity(0.9))
                        .padding(20)
                        .background(Circle().fill(Color.black.opacity(0.5)))
                        .transition(.opacity)
                }
                
                // Sleek Custom Glassmorphic Scrubber Bar
                VStack {
                    Spacer()
                    
                    HStack(spacing: isPadOrMac ? 16 : 12) {
                        // Play/Pause button
                        Button(action: togglePlayPause) {
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: isPadOrMac ? 18 : 16, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(width: isPadOrMac ? 44 : 36, height: isPadOrMac ? 44 : 36)
                                .background(Circle().fill(Color.white.opacity(0.2)))
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.space, modifiers: [])
                        
                        // Current time label
                        Text(formatTime(currentTime))
                            .font(.system(size: isPadOrMac ? 13 : 11, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.8))
                            .frame(width: isPadOrMac ? 50 : 42, alignment: .leading)
                        
                        // Scrubber Slider
                        Slider(value: Binding(
                            get: { currentTime },
                            set: { newValue in
                                currentTime = newValue
                                if isScrubbing {
                                    // Live seek scrubbing for highly interactive experience
                                    player.seek(to: CMTime(seconds: newValue, preferredTimescale: 1000))
                                }
                            }
                        ), in: 0...max(1, duration), onEditingChanged: { scrubbing in
                            isScrubbing = scrubbing
                            if scrubbing {
                                player.pause()
                            } else {
                                player.seek(to: CMTime(seconds: currentTime, preferredTimescale: 1000)) { _ in
                                    if isPlaying {
                                        player.play()
                                    }
                                }
                            }
                        })
                        .tint(Color.havenPurple)
                        
                        // Total duration label
                        Text(formatTime(duration))
                            .font(.system(size: isPadOrMac ? 13 : 11, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.8))
                            .frame(width: isPadOrMac ? 50 : 42, alignment: .trailing)
                        
                        // Mute button
                        Button(action: toggleMute) {
                            Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                .font(.system(size: isPadOrMac ? 17 : 15, weight: .medium))
                                .foregroundColor(.white)
                                .frame(width: isPadOrMac ? 44 : 36, height: isPadOrMac ? 44 : 36)
                                .background(Circle().fill(Color.white.opacity(0.2)))
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut("m", modifiers: [])
                        
                        // Hidden keyboard shortcut buttons for seeking
                        Button(action: seekBackward) { EmptyView() }
                            .keyboardShortcut(.leftArrow, modifiers: [])
                            .opacity(0)
                            .frame(width: 0, height: 0)
                        
                        Button(action: seekForward) { EmptyView() }
                            .keyboardShortcut(.rightArrow, modifiers: [])
                            .opacity(0)
                            .frame(width: 0, height: 0)
                    }
                    .padding(.horizontal, isPadOrMac ? 24 : 16)
                    .padding(.vertical, isPadOrMac ? 16 : 12)
                    .background(
                        RoundedRectangle(cornerRadius: isPadOrMac ? 24 : 16)
                            .fill(Color.black.opacity(0.5))
                            .background(.ultraThinMaterial)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: isPadOrMac ? 24 : 16)
                            .stroke(Color.white.opacity(isPadOrMac ? 0.15 : 0.08), lineWidth: 1)
                    )
                    .frame(maxWidth: isPadOrMac ? 640 : .infinity)
                    .padding(.horizontal, 20)
                    .padding(.bottom, isPadOrMac ? 32 : 20)
                }
            } else {
                ProgressView().tint(.white)
            }
        }
        .onAppear {
            VideoPlayerCache.shared.activeFullScreenURL = url
            setupPlayer()
        }
        .onDisappear {
            VideoPlayerCache.shared.activeFullScreenURL = nil
            removeTimeObserver()
            // Restore standard inline muted play
            player?.isMuted = true
            player = nil
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard !seconds.isNaN && !seconds.isInfinite else { return "00:00" }
        let secs = Int(seconds)
        let m = (secs % 3600) / 60
        let s = secs % 60
        return String(format: "%02d:%02d", m, s)
    }

    private func seekBackward() {
        guard let player = player else { return }
        let currentSeconds = CMTimeGetSeconds(player.currentTime())
        let targetSeconds = max(0, currentSeconds - 5)
        player.seek(to: CMTime(seconds: targetSeconds, preferredTimescale: 1000))
    }

    private func seekForward() {
        guard let player = player else { return }
        let currentSeconds = CMTimeGetSeconds(player.currentTime())
        let durationSeconds = duration
        let targetSeconds = min(durationSeconds, currentSeconds + 5)
        player.seek(to: CMTime(seconds: targetSeconds, preferredTimescale: 1000))
    }

    private func addTimeObserver() {
        guard let player = player else { return }
        
        // Initial duration fetch
        if let durationTime = player.currentItem?.duration {
            let durationSeconds = CMTimeGetSeconds(durationTime)
            if !durationSeconds.isNaN && !durationSeconds.isInfinite {
                self.duration = durationSeconds
            }
        }
        
        let interval = CMTime(seconds: 0.25, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak player] time in
            guard let player = player else { return }
            
            // Re-fetch duration in case it loaded asynchronously
            if let durationTime = player.currentItem?.duration {
                let durationSeconds = CMTimeGetSeconds(durationTime)
                if !durationSeconds.isNaN && !durationSeconds.isInfinite {
                    self.duration = durationSeconds
                }
            }
            
            if !isScrubbing {
                self.currentTime = CMTimeGetSeconds(time)
            }
        }
    }

    private func removeTimeObserver() {
        if let token = timeObserverToken {
            player?.removeTimeObserver(token)
            timeObserverToken = nil
        }
    }

    private func togglePlayPause() {
        if isPlaying {
            player?.pause()
        } else {
            player?.play()
        }
        isPlaying.toggle()
        withAnimation(.easeIn(duration: 0.1)) { showPlayIcon = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            withAnimation(.easeOut(duration: 0.3)) { showPlayIcon = false }
        }
    }

    private func toggleMute() {
        isMuted.toggle()
        player?.isMuted = isMuted
    }

    private func setupPlayer() {
        let cachedPlayer = VideoPlayerCache.shared.player(for: url)
        
        // Full screen default unmuted
        cachedPlayer.isMuted = isMuted
        
        self.player = cachedPlayer
        addTimeObserver()
        
        cachedPlayer.play()
        isPlaying = true
    }
}
