import SwiftUI
import AVKit
import AVFoundation

// MARK: - PiPManager

/// Owns the `AVPictureInPictureController` for the video in picture-in-picture:
/// the full-screen viewer's, a live stream's (also when it is the mini player's
/// shared player), or a feed video's (its PiP button). Lives beyond the SwiftUI
/// view hierarchy so PiP keeps rendering after the viewer is dismissed: it
/// retains the player layer until PiP actually stops. iPhone, iPad and Mac.
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
    /// The player belongs to someone else (the mini player's live stream):
    /// closing PiP leaves its sound and audio session alone (PiPRules).
    private var sharedPlayback = false
    /// `start()` was asked before PiP was possible: start as soon as it is.
    private var startWhenPossible = false

    static var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    func attach(layer: AVPlayerLayer, url: URL, shared: Bool = false) {
        guard Self.isSupported, !isPiPActive, playerLayer !== layer else { return }

        guard let pip = AVPictureInPictureController(playerLayer: layer) else { return }
        pip.delegate = self
        #if os(iOS)
        if #available(iOS 14.2, *) {
            // Swiping home while a full-screen video plays pops it into PiP automatically
            pip.canStartPictureInPictureAutomaticallyFromInline = true
        }
        #endif
        controller = pip
        playerLayer = layer
        activeURL = url
        sharedPlayback = shared
        startWhenPossible = false
        possibleObservation = pip.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] _, change in
            DispatchQueue.main.async {
                guard let self else { return }
                let possible = change.newValue ?? false
                self.isPiPPossible = possible
                if possible && self.startWhenPossible {
                    self.startWhenPossible = false
                    self.controller?.startPictureInPicture()
                }
            }
        }
    }

    /// Drops the controller when the presenting view goes away without starting PiP.
    func detach(url: URL) {
        guard !isPiPActive, activeURL == url else { return }
        teardown()
    }

    /// Starts PiP now, or as soon as the layer can (a feed video's button may
    /// be tapped before its controller is ready).
    func start() {
        guard let controller else { return }
        if controller.isPictureInPicturePossible {
            controller.startPictureInPicture()
        } else {
            startWhenPossible = true
        }
    }

    func stop() { controller?.stopPictureInPicture() }

    /// A feed video's PiP button: its layer goes to PiP with sound on.
    @MainActor
    func startInline(layer: AVPlayerLayer, url: URL, player: AVPlayer) {
        if isPiPActive && activeURL != url { stop() }
        VideoPlaybackService.shared.setMuted(false, on: player)
        attach(layer: layer, url: url)
        start()
    }

    /// True while PiP is rendering from this layer — the hosting view must not unhook its player.
    func ownsLayer(_ layer: AVPlayerLayer) -> Bool {
        isPiPActive && playerLayer === layer
    }

    /// True while PiP plays `url`.
    func isShowing(_ url: URL) -> Bool { isPiPActive && activeURL == url }

    private func teardown() {
        possibleObservation?.invalidate()
        possibleObservation = nil
        controller = nil
        playerLayer = nil
        activeURL = nil
        sharedPlayback = false
        startWhenPossible = false
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
        if PiPRules.pausesWhenClosed(sharedPlayback: sharedPlayback) {
            // PiP window closed: end playback and hand audio back to other apps.
            playerLayer?.player?.pause()
            playerLayer?.player?.isMuted = true
            // Only clear full-screen ownership if it's still ours — a new full-screen
            // video may have claimed it while stopping this PiP.
            if VideoPlayerCache.shared.activeFullScreenURL == activeURL {
                VideoPlayerCache.shared.activeFullScreenURL = nil
                AudioSessionManager.shared.enableMixingWithOthers()
            }
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
