import AVFoundation
import MediaPlayer

/// The lock screen and Control Center for the clip open full screen: its
/// play/pause, skip ±10 s and scrub, and a Now Playing line. While a clip
/// holds it, the music player's own command handlers stand aside
/// (`isActive`); on close the music's line and buttons come back.
@MainActor
final class VideoNowPlaying {
    static let shared = VideoNowPlaying()
    private init() {}

    /// Read by MusicPlayerService's command handlers, which the system calls
    /// on the main thread outside the actor.
    nonisolated(unsafe) static var isActive = false

    private var player: AVPlayer?
    private var title = ""
    private var isLive = false
    private var observers: [NSKeyValueObservation] = []
    private var targets: [(MPRemoteCommand, Any)] = []

    func begin(player: AVPlayer, title: String, isLive: Bool) {
        end()
        self.player = player
        self.title = title
        self.isLive = isLive
        Self.isActive = true
        registerCommands()
        observers = [
            player.observe(\.timeControlStatus) { _, _ in Task { @MainActor in VideoNowPlaying.shared.refresh() } },
            player.observe(\.rate) { _, _ in Task { @MainActor in VideoNowPlaying.shared.refresh() } },
        ]
        refresh()
    }

    /// `player` nil ends whichever clip holds it; otherwise only that one.
    func end(player: AVPlayer? = nil) {
        guard let current = self.player, player == nil || player === current else { return }
        observers.forEach { $0.invalidate() }
        observers.removeAll()
        for (command, target) in targets { command.removeTarget(target) }
        targets.removeAll()
        let center = MPRemoteCommandCenter.shared()
        center.skipBackwardCommand.isEnabled = false
        center.skipForwardCommand.isEnabled = false
        self.player = nil
        Self.isActive = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        // The music works its buttons out again rather than getting back a
        // snapshot from `begin`: its queue may have moved meanwhile.
        MusicPlayerService.shared.refreshRemoteCommandStates()
        MusicPlayerService.shared.updateNowPlaying()
    }

    /// Elapsed time and rate as they are now; the system runs the clock on
    /// from these, so this is needed only on play, pause, seek and speed.
    func refresh() {
        guard let player else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: "Nostr Vault",
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(0, CMTimeGetSeconds(player.currentTime()).finiteOrZero),
            MPNowPlayingInfoPropertyPlaybackRate: Double(player.rate),
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(player.defaultRate),
        ]
        let length = player.currentItem.map { CMTimeGetSeconds($0.duration) } ?? .nan
        if isLive {
            info[MPNowPlayingInfoPropertyIsLiveStream] = true
        } else if length.isFinite, length > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = length
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        #if os(macOS)
        MPNowPlayingInfoCenter.default().playbackState = player.timeControlStatus == .paused ? .paused : .playing
        #endif
    }

    /// Skip `seconds` within the clip; the control bar and the lock screen.
    static func skip(_ player: AVPlayer, by seconds: Double) {
        let current = CMTimeGetSeconds(player.currentTime())
        let length = player.currentItem.map { CMTimeGetSeconds($0.duration) }
        let target = VideoPlayerControls.skipTarget(current: current, by: seconds, duration: length)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            Task { @MainActor in VideoNowPlaying.shared.refresh() }
        }
    }

    private func registerCommands() {
        let center = MPRemoteCommandCenter.shared()
        let seekable = VideoPlayerControls.showsSpeedAndSkip(isLive: isLive)
        let states: [(MPRemoteCommand, Bool)] = [
            (center.nextTrackCommand, false), (center.previousTrackCommand, false),
            (center.skipBackwardCommand, seekable), (center.skipForwardCommand, seekable),
            (center.changePlaybackPositionCommand, seekable),
        ]
        for (command, enabled) in states { command.isEnabled = enabled }
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: VideoPlayerControls.skipSeconds)]
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: VideoPlayerControls.skipSeconds)]

        add(center.playCommand) { $0.play() }
        add(center.pauseCommand) { $0.pause() }
        add(center.togglePlayPauseCommand) { $0.timeControlStatus == .paused ? $0.play() : $0.pause() }
        add(center.skipBackwardCommand) { Self.skip($0, by: -VideoPlayerControls.skipSeconds) }
        add(center.skipForwardCommand) { Self.skip($0, by: VideoPlayerControls.skipSeconds) }
        let position = center.changePlaybackPositionCommand.addTarget { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            MainActor.assumeIsolated {
                VideoNowPlaying.shared.player?.seek(to: CMTime(seconds: event.positionTime, preferredTimescale: 600)) { _ in
                    Task { @MainActor in VideoNowPlaying.shared.refresh() }
                }
            }
            return .success
        }
        targets.append((center.changePlaybackPositionCommand, position))
    }

    private func add(_ command: MPRemoteCommand, _ action: @escaping @MainActor (AVPlayer) -> Void) {
        let target = command.addTarget { _ in
            MainActor.assumeIsolated {
                guard let player = VideoNowPlaying.shared.player else { return .noActionableNowPlayingItem }
                action(player)
                return .success
            }
        }
        targets.append((command, target))
    }
}

private extension Double {
    var finiteOrZero: Double { isFinite ? self : 0 }
}
