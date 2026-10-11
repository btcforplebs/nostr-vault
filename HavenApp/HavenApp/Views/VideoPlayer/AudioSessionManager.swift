import SwiftUI
import AVKit
import AVFoundation

// MARK: - Audio Session Manager

/// Manages audio session configuration for video playback.
/// Switches between ambient (mixing with background music) and playback (taking over audio) modes.
class AudioSessionManager {
    static let shared = AudioSessionManager()

    /// True while the app-wide player (`MusicPlayerService`: a song, or a
    /// minimized live stream) is playing. Video surfaces hand the session back
    /// to `.ambient` when they go — and `.ambient` is silenced by the lock
    /// screen and the ring/silent switch, so doing that under the mini player
    /// killed its sound the moment the phone locked. Minimizing a live stream
    /// did it every time: the dismissed video player restored mixing right
    /// after the mini player had claimed `.playback`.
    var appAudioIsPlaying = false

    /// Pauses the app-wide player when a video takes the sound over. Taking
    /// the session deactivates it, which silences the mini player without
    /// telling it, so it went on showing "playing" with nothing coming out.
    var pauseAppAudio: (() -> Void)?

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
        // The mini player owns the session; see `appAudioIsPlaying`.
        if appAudioIsPlaying { return }
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
            if appAudioIsPlaying { pauseAppAudio?() }
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
