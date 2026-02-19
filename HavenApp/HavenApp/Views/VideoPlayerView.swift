import SwiftUI
import AVKit
import AVFoundation

struct VideoPlayerView: View {
    let url: URL
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
            .onChange(of: geo.size) { oldValue, newSize in
                // Strict size gate: Don't load player unless we have enough width for the controls
                if viewSize == .zero && newSize.width > 300 {
                    viewSize = newSize
                    setupPlayer()
                }
            }
            .onAppear {
                if geo.size.width > 300 {
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
                print("VideoPlayerView: Local file missing at \(actualPath)")
                loadError = "Local file not found."
                return
            }
            
            if let attr = try? FileManager.default.attributesOfItem(atPath: actualPath),
               let size = attr[.size] as? UInt64, size < 200 {
                print("VideoPlayerView: File too small (\(size) bytes)")
                loadError = "Video file is invalid or too small."
                return
            }
        }
        
        // Strict Constraint Safety: 
        // AVPlayerViewController (AppKit backend) throws constraint exceptions if initialized 
        // with near-zero frames. We must ensure we are ready.
        if viewSize.width < 100 || viewSize.height < 100 {
            print("VideoPlayerView: Skipping setup - view too small (\(viewSize))")
            return
        }
        
        print("VideoPlayerView: Setting up player for \(finalURL.lastPathComponent)")
        let asset = AVURLAsset(url: finalURL)
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

struct NativeVideoPlayer: NSViewRepresentable {
    let player: AVPlayer
    
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.allowedTouchTypes = .indirect // standard for mac
        return view
    }
    
    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player != player {
            nsView.player = player
        }
    }
}
