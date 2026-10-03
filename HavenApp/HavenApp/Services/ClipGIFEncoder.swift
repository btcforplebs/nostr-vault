import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Turns a short video clip into a looping GIF, on device.
///
/// getyarn burns the quote into every full-size GIF it serves
/// (`_text_hi.gif`); its only textless GIF is a 200px preview. The clip's MP4
/// is clean and larger (854×480), so a textless GIF is made from that.
enum ClipGIFEncoder {
    enum EncodeError: Error { case noVideo, encodeFailed, tooLarge }

    /// Encodes `videoURL` (a local file) as a looping GIF no bigger than
    /// `maxBytes`, stepping width and frame rate down until it fits.
    static func gif(fromVideoAt videoURL: URL, maxBytes: Int, maxSeconds: Double = 8) async throws -> Data {
        let asset = AVURLAsset(url: videoURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw EncodeError.noVideo }
        let duration = min(try await asset.load(.duration).seconds, maxSeconds)
        let natural = try await track.load(.naturalSize)
        guard duration > 0, natural.width > 0 else { throw EncodeError.noVideo }

        // Largest first; each step trades size for detail.
        let attempts: [(width: CGFloat, fps: Double)] = [(480, 12), (400, 10), (320, 10), (240, 8)]
        for attempt in attempts {
            let width = min(attempt.width, natural.width)
            let size = CGSize(width: width, height: (natural.height * width / natural.width).rounded())
            let data = try await encode(asset: asset, duration: duration, size: size, fps: attempt.fps)
            if data.count <= maxBytes { return data }
        }
        throw EncodeError.tooLarge
    }

    private static func encode(asset: AVAsset, duration: Double, size: CGSize, fps: Double) async throws -> Data {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = size
        // Frames at exact times, not the nearest keyframe, or the loop stutters.
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let frameCount = max(1, Int((duration * fps).rounded(.down)))
        let delay = 1.0 / fps
        var frames: [CGImage] = []
        for i in 0..<frameCount {
            let time = CMTime(seconds: Double(i) * delay, preferredTimescale: 600)
            if let (image, _) = try? await generator.image(at: time) { frames.append(image) }
        }
        guard !frames.isEmpty else { throw EncodeError.encodeFailed }

        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.gif.identifier as CFString, frames.count, nil) else {
            throw EncodeError.encodeFailed
        }
        CGImageDestinationSetProperties(dest, [
            kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFLoopCount as String: 0],
        ] as CFDictionary)
        let frameProps = [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFDelayTime as String: delay,
                kCGImagePropertyGIFUnclampedDelayTime as String: delay,
            ],
        ] as CFDictionary
        for frame in frames { CGImageDestinationAddImage(dest, frame, frameProps) }
        guard CGImageDestinationFinalize(dest) else { throw EncodeError.encodeFailed }
        return out as Data
    }
}
