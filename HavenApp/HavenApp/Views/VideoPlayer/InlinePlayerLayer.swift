import SwiftUI
import AVKit
import AVFoundation

// MARK: - InlinePlayerLayer (chromeless AVPlayerLayer)

#if os(macOS)
struct InlinePlayerLayer: NSViewRepresentable {
    let player: AVPlayer
    var videoGravity: AVLayerVideoGravity = .resizeAspectFill
    /// Called with the backing AVPlayerLayer once created (used to wire up PiP on iOS).
    var onLayerReady: ((AVPlayerLayer) -> Void)? = nil
    /// iOS only: macOS keeps a layer's player playing in the background.
    var keepsPlayingInBackground = false

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
    /// For a player whose sound carries on without its picture — the mini
    /// player's live stream. iOS pauses any player still attached to a layer
    /// when the app goes to the background, so showing the stream's video in
    /// the mini player (or the pop-out window) stopped its sound the moment
    /// you left the app (Logen, 2026-10-06). The layer lets go of the player
    /// while the app is away and takes it back on return.
    var keepsPlayingInBackground = false

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.keepsPlayingInBackground = keepsPlayingInBackground
        view.attach(player)
        view.playerLayer.videoGravity = videoGravity
        onLayerReady?(view.playerLayer)
        return view
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {
        uiView.keepsPlayingInBackground = keepsPlayingInBackground
        uiView.attach(player)
        if uiView.playerLayer.videoGravity != videoGravity {
            uiView.playerLayer.videoGravity = videoGravity
        }
    }
    
    static func dismantleUIView(_ uiView: PlayerUIView, coordinator: Coordinator) {
        // PiP keeps rendering from this layer after the view leaves the hierarchy —
        // unhooking the player here would blank the PiP window.
        if PiPManager.shared.ownsLayer(uiView.playerLayer) { return }
        uiView.parkedPlayer = nil
        uiView.playerLayer.player = nil
    }

    class PlayerUIView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

        var keepsPlayingInBackground = false
        /// The player let go of while the app is in the background.
        fileprivate var parkedPlayer: AVPlayer?
        private var observers: [NSObjectProtocol] = []

        override init(frame: CGRect) {
            super.init(frame: frame)
            let center = NotificationCenter.default
            observers = [
                center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                   object: nil, queue: .main) { [weak self] _ in self?.park() },
                center.addObserver(forName: UIApplication.willEnterForegroundNotification,
                                   object: nil, queue: .main) { [weak self] _ in self?.unpark() },
            ]
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }

        /// Shows `player`, or holds it until the app is back if it is parked.
        func attach(_ player: AVPlayer) {
            if parkedPlayer != nil {
                parkedPlayer = player
            } else if playerLayer.player != player {
                playerLayer.player = player
            }
        }

        private func park() {
            guard keepsPlayingInBackground, let player = playerLayer.player,
                  !PiPManager.shared.ownsLayer(playerLayer) else { return }
            parkedPlayer = player
            playerLayer.player = nil
        }

        private func unpark() {
            guard let player = parkedPlayer else { return }
            parkedPlayer = nil
            playerLayer.player = player
        }
    }
}
#endif
