import AVFoundation
import Foundation

/// A full-screen clip handed to the mini player (Minimize): the asset the
/// viewer was playing — a cached or mesh-rescued file, with its MIME
/// override — and where to pick it up.
struct VideoHandOff {
    let trackID: String
    let asset: AVAsset
    /// Seconds in; cleared once used, so a reload after a failure starts
    /// from the bar's own time rather than the tap's.
    var start: Double?
}

extension PlayerTrack {
    /// Live and clips: the bar's player is also shown as video (the round
    /// artwork, and the window it reopens), whose own controls play and pause it.
    var sharesPlayer: Bool { isLive || isVideo }
    /// No repeat and no next: a stream has no end, and a clip plays once.
    var playsOnce: Bool { isLive || isVideo }
}

extension MusicPlayerService {
    /// The player behind a minimized clip, for the viewer it reopens: the
    /// same player, so the sound plays straight through and the viewer
    /// opens at the bar's time.
    var videoPlayer: AVPlayer? { current?.isVideo == true ? visiblePlayer : nil }

    /// Minimize on a full-screen clip: its sound carries on in the mini
    /// player from `start`, and plays once. Replaces whatever was queued,
    /// as a minimized live stream does.
    func playVideo(asset: AVAsset, url: URL, at start: Double, duration: Double?,
                   title: String, artist: String, artworkURL: URL?) {
        let id = "video:\(url.absoluteString)"
        videoHandOff = VideoHandOff(trackID: id, asset: asset, start: start.isFinite ? max(0, start) : nil)
        play(tracks: [PlayerTrack(
            id: id, title: title, artist: artist, artworkURL: artworkURL, audioURL: url,
            duration: duration.flatMap { $0.isFinite && $0 > 0 ? Int($0) : nil }, isVideo: true
        )], startAt: 0)
    }

    /// The viewer's own asset in a new item, so a local or mesh file and its
    /// MIME type carry over and nothing downloads again.
    func handedOverItem(for track: PlayerTrack) -> AVPlayerItem? {
        guard track.isVideo, let handOff = videoHandOff, handOff.trackID == track.id else { return nil }
        return AVPlayerItem(asset: handOff.asset)
    }

    /// Where the handed-over clip starts, once: a reload after a failure
    /// starts over rather than jumping back to the tap's time.
    func takeHandOffStart(for track: PlayerTrack) -> Double? {
        guard track.isVideo, let handOff = videoHandOff, handOff.trackID == track.id,
              let start = handOff.start else { return nil }
        videoHandOff?.start = nil
        return start > 0.5 ? start : nil
    }

    /// A clip waiting for its first seek: it starts playing once that lands,
    /// so the sound never blips from 0:00 first.
    func waitsForHandOffSeek(_ track: PlayerTrack) -> Bool {
        guard track.isVideo, let handOff = videoHandOff, handOff.trackID == track.id,
              let start = handOff.start else { return false }
        return start > 0.5
    }
}
