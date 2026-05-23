import SwiftUI
import AVKit
import AVFoundation

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
    @State private var player: AVPlayer?
    @State private var isMuted: Bool = true
    @State private var isPlaying: Bool = false
    @State private var loadError: String? = nil
    @State private var thumbnail: PlatformImage? = nil
    @State private var loopObserver: NSObjectProtocol? = nil

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
                    InlinePlayerLayer(player: player)
                        .frame(width: geo.size.width, height: geo.size.height)
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
                player?.pause()
                isPlaying = false
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
        let finalURL = MediaCacheService.shared.preparePlayableURL(for: url) ?? url

        // Safety check for local files
        if finalURL.isFileURL {
            let actualPath = finalURL.resolvingSymlinksInPath().path
            if !FileManager.default.fileExists(atPath: actualPath) {
                loadError = "File not found"
                return
            }
        }

        // Build asset with MIME hint for extensionless URLs
        var assetOptions: [String: Any] = [:]
        if !finalURL.isFileURL && finalURL.pathExtension.isEmpty {
            let mimeType = MediaTypeDetector.shared.getCachedContentType(for: url) ?? "video/mp4"
            assetOptions[AVURLAssetOverrideMIMETypeKey] = mimeType
        }

        let asset = AVURLAsset(url: finalURL, options: assetOptions)
        let playerItem = AVPlayerItem(asset: asset)
        let newPlayer = AVPlayer(playerItem: playerItem)
        newPlayer.isMuted = true

        // Loop: when playback ends, seek back to start
        let observer = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { _ in
            newPlayer.seek(to: .zero)
            newPlayer.play()
        }
        self.loopObserver = observer

        self.player = newPlayer
        newPlayer.play()
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
/// Matches the visual language of InlineFeedVideoPlayer but unmuted, with tap-to-pause.
struct FullScreenVideoPlayer: View {
    let url: URL
    var mimeType: String? = nil

    @State private var player: AVPlayer?
    @State private var isMuted: Bool = false
    @State private var isPlaying: Bool = true
    @State private var showPlayIcon: Bool = false
    @State private var loadError: String? = nil
    @State private var loopObserver: NSObjectProtocol? = nil

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
            } else {
                ProgressView().tint(.white)
            }

            // Mute button — bottom right, same style as inline player
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button(action: toggleMute) {
                        Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.white)
                            .padding(10)
                            .background(Circle().fill(Color.black.opacity(0.6)))
                    }
                    .buttonStyle(.plain)
                    .padding(16)
                }
            }
        }
        .onAppear { setupPlayer() }
        .onDisappear {
            player?.pause()
            if let obs = loopObserver {
                NotificationCenter.default.removeObserver(obs)
            }
            player = nil
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
        let finalURL = MediaCacheService.shared.preparePlayableURL(for: url) ?? url

        if finalURL.isFileURL {
            let actualPath = finalURL.resolvingSymlinksInPath().path
            guard FileManager.default.fileExists(atPath: actualPath) else {
                loadError = "File not found"
                return
            }
        }

        var assetOptions: [String: Any] = [:]
        if !finalURL.isFileURL && finalURL.pathExtension.isEmpty {
            let resolved = mimeType
                ?? MediaTypeDetector.shared.getCachedContentType(for: url)
                ?? "video/mp4"
            assetOptions[AVURLAssetOverrideMIMETypeKey] = resolved
        }

        let asset = AVURLAsset(url: finalURL, options: assetOptions)
        let playerItem = AVPlayerItem(asset: asset)
        let newPlayer = AVPlayer(playerItem: playerItem)
        newPlayer.isMuted = false

        let observer = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { _ in
            newPlayer.seek(to: .zero)
            newPlayer.play()
        }
        loopObserver = observer

        self.player = newPlayer
        newPlayer.play()
        isPlaying = true
    }
}
