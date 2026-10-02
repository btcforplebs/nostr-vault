import AVFoundation
import Combine
import Foundation
import MediaPlayer
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Something the app-wide player can play: a Wavlake song, or the sound of
/// a live stream (so a stream keeps going in the mini player and on the
/// lock screen while you browse).
struct PlayerTrack: Identifiable, Hashable {
    let id: String
    let title: String
    let artist: String
    let artworkURL: URL?
    let audioURL: URL?
    let duration: Int?
    var isLive = false
    var albumTitle: String? = nil
    var pageURL: URL? = nil
    /// The song behind this item, for Share and the artist's profile.
    var wavlake: WavlakeTrack? = nil
    /// A live stream's host, for opening their profile.
    var hostPubkey: String? = nil
}

extension PlayerTrack {
    init(_ track: WavlakeTrack) {
        self.init(id: track.id, title: track.title, artist: track.artist,
                  artworkURL: track.artworkURL, audioURL: track.audioURL, duration: track.duration,
                  albumTitle: track.albumTitle, pageURL: track.pageURL, wavlake: track)
    }
}

/// Plays Wavlake tracks and live-stream audio app-wide: keeps going while you browse, switch tabs
/// or lock the phone, and shows on the lock screen / Control Center (and
/// the Mac's Now Playing) with play, pause, next, previous and scrubbing.
@MainActor
final class MusicPlayerService: ObservableObject {
    static let shared = MusicPlayerService()

    @Published private(set) var queue: [PlayerTrack] = []
    @Published private(set) var index: Int = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = false
    /// Seconds into the current track, refreshed twice a second while playing.
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var duration: Double = 0

    /// The stream behind a minimized live item, so the full player can
    /// bring its video back.
    @Published private(set) var liveStream: LiveStream?

    var current: PlayerTrack? { queue.indices.contains(index) ? queue[index] : nil }
    var hasNext: Bool { index + 1 < queue.count }

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var bufferingObservation: NSKeyValueObservation?
    private var artwork: MPMediaItemArtwork?
    private var artworkTask: Task<Void, Never>?

    private init() {
        player.automaticallyWaitsToMinimizeStalling = true
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time) }
        }
        bufferingObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let waiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            Task { @MainActor in self?.isBuffering = waiting }
        }
        configureRemoteCommands()
        #if os(iOS)
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated { self?.handleInterruption(note) }
        }
        #endif
    }

    // MARK: - Public controls

    /// Plays Wavlake `tracks` from `startIndex`; the rest queue up after it.
    func play(_ tracks: [WavlakeTrack], startAt startIndex: Int = 0) {
        play(tracks: tracks.map(PlayerTrack.init), startAt: startIndex)
    }

    /// Listens to a live stream: sound only, in the mini player and on the
    /// lock screen. Replaces whatever was queued.
    func playLive(stream: LiveStream, item: PlayerTrack) {
        play(tracks: [item], startAt: 0)
        liveStream = stream
    }

    func play(tracks: [PlayerTrack], startAt startIndex: Int = 0) {
        guard tracks.indices.contains(startIndex) else { return }
        liveStream = nil
        queue = tracks
        index = startIndex
        loadCurrent(autoplay: true)
    }

    func togglePlayPause() {
        isPlaying ? pause() : resume()
    }

    func resume() {
        guard current != nil else { return }
        activateSession()
        player.play()
        isPlaying = true
        updateNowPlaying()
    }

    func pause() {
        player.pause()
        isPlaying = false
        updateNowPlaying()
    }

    func next() {
        guard hasNext else { return }
        index += 1
        loadCurrent(autoplay: true)
    }

    /// Back to the previous track, or to the start of this one when it has
    /// played for more than a few seconds — the way every music app does it.
    func previous() {
        if current?.isLive == true { return }
        if elapsed > 3 || index == 0 {
            seek(to: 0)
        } else {
            index -= 1
            loadCurrent(autoplay: true)
        }
    }

    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600))
        elapsed = max(0, seconds)
        updateNowPlaying()
    }

    /// Stops and clears the queue; the mini player goes away.
    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        queue = []
        liveStream = nil
        index = 0
        isPlaying = false
        elapsed = 0
        duration = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        deactivateSession()
    }

    // MARK: - Loading

    private func loadCurrent(autoplay: Bool) {
        guard let track = current, let url = track.audioURL else { return }
        let item = makeItem(url: url, isLive: track.isLive)
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let seconds = item.duration.seconds
            Task { @MainActor in
                guard let self else { return }
                if seconds.isFinite, seconds > 0 { self.duration = seconds }
                if item.status == .failed, self.hasNext { self.next() }
            }
        }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackEnded() }
        }
        elapsed = 0
        duration = Double(track.duration ?? 0)
        let commands = MPRemoteCommandCenter.shared()
        commands.changePlaybackPositionCommand.isEnabled = !track.isLive
        commands.nextTrackCommand.isEnabled = hasNext
        commands.previousTrackCommand.isEnabled = !track.isLive
        player.replaceCurrentItem(with: item)
        loadArtwork(for: track)
        if autoplay { resume() } else { updateNowPlaying() }
    }

    /// A live HLS stream plays through `HLSLowLatencyStripper`: zap.stream's
    /// low-latency playlists fail outright in AVPlayer, and plain live HLS
    /// plays everywhere, a couple of seconds further behind.
    private func makeItem(url: URL, isLive: Bool) -> AVPlayerItem {
        if isLive, url.pathExtension.lowercased() == "m3u8", let wrapped = HLSLowLatencyStripper.wrap(url) {
            let asset = AVURLAsset(url: wrapped)
            asset.resourceLoader.setDelegate(HLSLowLatencyStripper.shared, queue: HLSLowLatencyStripper.shared.queue)
            return AVPlayerItem(asset: asset)
        }
        return AVPlayerItem(url: url)
    }

    private func trackEnded() {
        if hasNext {
            next()
        } else {
            isPlaying = false
            seek(to: 0)
        }
    }

    private func tick(_ time: CMTime) {
        let seconds = time.seconds
        guard seconds.isFinite else { return }
        elapsed = seconds
    }

    // MARK: - Audio session

    /// The app runs `.ambient` so muted feed videos never stop your music
    /// from other apps. Music needs `.playback`, which is what keeps it
    /// going in the background and with the ring/silent switch on.
    private func activateSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])
        try? session.setActive(true)
        #endif
    }

    private func deactivateSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        try? session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
        #endif
    }

    #if os(iOS)
    private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            if isPlaying { isPlaying = false; updateNowPlaying() }
        case .ended:
            let options = AVAudioSession.InterruptionOptions(
                rawValue: info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            if options.contains(.shouldResume), current != nil { resume() }
        @unknown default:
            break
        }
    }
    #endif

    // MARK: - Lock screen / Now Playing

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(to: event.positionTime) }
            return .success
        }
    }

    private func updateNowPlaying() {
        guard let track = current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let album = track.albumTitle { info[MPMediaItemPropertyAlbumTitle] = album }
        if track.isLive {
            info[MPNowPlayingInfoPropertyIsLiveStream] = true
        } else if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        #if os(macOS)
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
        #endif
    }

    private func loadArtwork(for track: PlayerTrack) {
        artworkTask?.cancel()
        artwork = nil
        guard let url = track.artworkURL else { return }
        artworkTask = Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url), !Task.isCancelled else { return }
            #if os(iOS)
            guard let image = UIImage(data: data) else { return }
            #else
            guard let image = NSImage(data: data) else { return }
            #endif
            let art = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            await MainActor.run {
                guard let self, self.current?.id == track.id else { return }
                self.artwork = art
                self.updateNowPlaying()
            }
        }
    }
}
