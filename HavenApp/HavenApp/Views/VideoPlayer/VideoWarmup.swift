#if os(iOS)
import SwiftUI
import UIKit
import AVFoundation

/// Pays the first video row's one-time cost at idle, once per launch.
///
/// The first `InlineFeedVideoPlayer` a launch draws makes SwiftUI build that
/// view's generic types for the first time, and its player makes AVFoundation
/// start up (AVPlayer, AVPlayerLayer, Fig logging, KVO). On the sim that froze
/// a coasting feed twice: 456 ms + 197 ms after install, 106 ms + 90 ms on a
/// relaunch, while later videos cost 0-41 ms (Tom, coast hitch 11-26 #1).
///
/// So once the feed's first rows are on screen this hosts one real
/// `InlineFeedVideoPlayer`, hidden and off screen, on a tiny silent clip
/// written to Caches, lets it reach its player branch, then removes it.
@MainActor
enum VideoWarmup {
    private static var started = false
    private static var host: UIHostingController<InlineFeedVideoPlayer>?

    /// Waits for the frames after the first rows to settle, then warms up.
    static func runOnce(after delay: Duration = .milliseconds(1500)) {
        guard !started else { return }
        started = true
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard let clip = await Task.detached(priority: .utility, operation: { WarmupClip.url() }).value else { return }
            mount(clip)
        }
    }

    private static func mount(_ clip: URL) {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else { return }
        let controller = UIHostingController(rootView: InlineFeedVideoPlayer(url: clip))
        let view = controller.view!
        // Wider than the player's 50 pt setup floor, above the window's top,
        // invisible and out of touch and VoiceOver.
        view.frame = CGRect(x: 0, y: -400, width: 160, height: 90)
        view.alpha = 0
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        window.addSubview(view)
        host = controller
        RelayProcessManager.shared.startupMark("video warm-up mounted")
        Task { @MainActor in
            // The player is set up 0.3 s after appear; leave time for its layer.
            try? await Task.sleep(for: .seconds(2))
            unmount(clip)
        }
    }

    private static func unmount(_ clip: URL) {
        host?.view.removeFromSuperview()
        host = nil
        VideoPlayerCache.shared.storedPlayer(for: clip)?.pause()
        VideoPlayerCache.shared.removePlayer(for: clip)
        RelayProcessManager.shared.startupMark("video warm-up done")
    }
}

/// A 16x16, two-frame H.264 clip in Caches, written once.
private enum WarmupClip {
    nonisolated static func url() -> URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let url = caches.appendingPathComponent("video-warmup-v1.mp4")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        return write(to: url) ? url : nil
    }

    nonisolated private static func write(to url: URL) -> Bool {
        let tmp = url.deletingLastPathComponent().appendingPathComponent("video-warmup-\(UUID().uuidString).mp4")
        guard let writer = try? AVAssetWriter(outputURL: tmp, fileType: .mp4) else { return false }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 16, AVVideoHeightKey: 16
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 16, kCVPixelBufferHeightKey as String: 16
        ])
        guard writer.canAdd(input) else { return false }
        writer.add(input)
        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<2 {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let buffer else { return false }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                memset(base, 0, CVPixelBufferGetDataSize(buffer))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            while !input.isReadyForMoreMediaData { usleep(1000) }
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10)) else { return false }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 2, timescale: 10))
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else { return false }
        try? FileManager.default.moveItem(at: tmp, to: url)
        return FileManager.default.fileExists(atPath: url.path)
    }
}
#endif
