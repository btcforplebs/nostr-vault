import SwiftUI
import AVKit
import AVFoundation

// MARK: - VideoControlBar

/// Bottom control rail for the full-screen player:
/// play/pause · elapsed · scrubber · duration · mute · PiP.
struct VideoControlBar: View {
    let player: AVPlayer
    /// Non-nil shows the PiP button (iOS devices where PiP is currently possible).
    var onPiP: (() -> Void)? = nil
    /// Called on any control interaction so the container can restart its auto-hide timer.
    var onInteract: (() -> Void)? = nil
    /// Play for a live stream: rejoins the broadcast instead of `play()`,
    /// which does nothing on an item left behind the live window.
    var onResumeLive: (() -> Void)? = nil

    @State private var isPlaying: Bool = true
    @State private var isMuted: Bool = false
    @State private var elapsed: Double = 0
    @State private var duration: Double = 0
    @State private var timeObserver: Any?

    var body: some View {
        HStack(spacing: 12) {
            Button {
                onInteract?()
                if isPlaying {
                    player.pause()
                } else if let onResumeLive {
                    onResumeLive()
                } else {
                    player.play()
                }
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.appSystem(size: 18, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text(Self.timeString(elapsed))
                .font(.appSystem(size: 12, weight: .medium).monospacedDigit())
                .foregroundColor(.white.opacity(0.85))

            VideoScrubber(player: player, onScrub: { onInteract?() })

            Text(Self.timeString(duration))
                .font(.appSystem(size: 12, weight: .medium).monospacedDigit())
                .foregroundColor(.white.opacity(0.85))

            Button {
                onInteract?()
                isMuted.toggle()
                player.isMuted = isMuted
            } label: {
                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.appSystem(size: 15, weight: .medium))
                    .foregroundColor(.white)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let onPiP = onPiP {
                Button {
                    onPiP()
                } label: {
                    Image(systemName: "pip.enter")
                        .font(.appSystem(size: 15, weight: .medium))
                        .foregroundColor(.white)
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .onReceive(player.publisher(for: \.timeControlStatus)) { status in
            isPlaying = (status != .paused)
        }
        .onAppear {
            isMuted = player.isMuted
            startObserving()
        }
        .onDisappear { stopObserving() }
    }

    private func startObserving() {
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            elapsed = CMTimeGetSeconds(time)
            if let itemDuration = player.currentItem?.duration,
               itemDuration.isValid, !itemDuration.isIndefinite {
                duration = CMTimeGetSeconds(itemDuration)
            }
        }
    }

    private func stopObserving() {
        if let observer = timeObserver {
            player.removeTimeObserver(observer)
            timeObserver = nil
        }
    }

    static func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}
