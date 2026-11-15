import SwiftUI
import AVKit
import AVFoundation

// MARK: - Mac standalone player (native controls)
//
// The Mac Media page plays clips in AppKit's AVPlayerView. iPhone and iPad
// play every big clip in FullScreenVideoPlayer instead (one player, one look).

#if os(macOS)
struct NativeVideoPlayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        // The Mac's own PiP button in the controls (PiP plan lane B).
        view.allowsPictureInPicturePlayback = true
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player != player {
            nsView.player = player
        }
    }
}
#endif
