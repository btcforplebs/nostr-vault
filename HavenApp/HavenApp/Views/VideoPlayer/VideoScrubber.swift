import SwiftUI
import AVKit
import AVFoundation

// MARK: - VideoScrubber

/// Minimal seek bar — thin progress line with drag-to-seek.
struct VideoScrubber: View {
    let player: AVPlayer
    /// Fired on every drag update so a container can keep its auto-hiding controls visible.
    var onScrub: (() -> Void)? = nil

    @State private var progress: Double = 0
    @State private var isDragging: Bool = false
    @State private var timeObserver: Any?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.3))
                    .frame(height: 3)

                Capsule()
                    .fill(Color.white.opacity(0.85))
                    .frame(width: max(0, geo.size.width * progress), height: isDragging ? 5 : 3)
                    .animation(Motion.control, value: isDragging)
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        onScrub?()
                        let fraction = min(max(value.location.x / geo.size.width, 0), 1)
                        progress = fraction
                        seek(to: fraction)
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
        }
        .frame(height: 20) // generous hit target
        .onAppear { startObserving() }
        .onDisappear { stopObserving() }
    }

    private func startObserving() {
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            guard !isDragging else { return }
            guard let duration = player.currentItem?.duration,
                  duration.isValid, !duration.isIndefinite else { return }
            let total = CMTimeGetSeconds(duration)
            guard total > 0 else { return }
            progress = CMTimeGetSeconds(time) / total
        }
    }

    private func stopObserving() {
        if let observer = timeObserver {
            player.removeTimeObserver(observer)
            timeObserver = nil
        }
    }

    private func seek(to fraction: Double) {
        guard let duration = player.currentItem?.duration,
              duration.isValid, !duration.isIndefinite else { return }
        let target = CMTimeGetSeconds(duration) * fraction
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
    }
}
