import SwiftUI
import AVKit
import AVFoundation

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
