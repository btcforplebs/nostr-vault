import AVFoundation

/// Keeps a live stream that is only listened to on its smallest HLS variant.
/// AVPlayer falls back to the lowest variant when none fits under the peak
/// bitrate, so asking for 64 kbps gets the audio-only rendition where the
/// stream has one and the lowest video one where it does not.
enum SoundOnlyStream {
    static let peakBitRate: Double = 64_000

    static func limit(_ item: AVPlayerItem) {
        item.preferredPeakBitRate = peakBitRate
        item.preferredMaximumResolution = CGSize(width: 1, height: 1)
    }
}
