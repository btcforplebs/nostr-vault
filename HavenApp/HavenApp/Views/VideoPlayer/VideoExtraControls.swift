import SwiftUI
import AVFoundation

/// The row above the full-screen player's scrubber: skip back and forward,
/// speed, captions, AirPlay and PiP (Logen 2026-11-19: keep our player, add
/// what the system one has). A live stream leaves out skip and speed.
struct VideoExtraControls: View {
    let player: AVPlayer
    let isLive: Bool
    var onPiP: (() -> Void)? = nil
    var onInteract: (() -> Void)? = nil

    @State private var rate: Float = 1

    var body: some View {
        HStack(spacing: 4) {
            if VideoPlayerControls.showsSpeedAndSkip(isLive: isLive) {
                iconButton("gobackward.10", label: "Back 10 seconds") { skip(-VideoPlayerControls.skipSeconds) }
                iconButton("goforward.10", label: "Forward 10 seconds") { skip(VideoPlayerControls.skipSeconds) }
            }
            Spacer(minLength: 0)
            if VideoPlayerControls.showsSpeedAndSkip(isLive: isLive) {
                speedMenu
            }
            VideoCaptionsMenu(player: player, onInteract: onInteract)
            VideoAirPlayButton(onTap: onInteract)
            if let onPiP {
                iconButton("pip.enter", label: "Picture in Picture", action: onPiP)
            }
        }
        .onAppear { rate = player.defaultRate }
    }

    private var speedMenu: some View {
        Menu {
            ForEach(VideoPlayerControls.speeds, id: \.self) { speed in
                Button { setRate(speed) } label: {
                    if speed == rate {
                        Label(VideoPlayerControls.speedLabel(speed), systemImage: "checkmark")
                    } else {
                        Text(VideoPlayerControls.speedLabel(speed))
                    }
                }
            }
        } label: {
            Text(VideoPlayerControls.speedLabel(rate))
                .font(.appSystem(size: 13, weight: .semibold).monospacedDigit())
                .foregroundColor(.white)
                .frame(minWidth: 34, minHeight: 34)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel("Playback speed")
        .accessibilityValue(VideoPlayerControls.speedLabel(rate))
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button {
            onInteract?()
            action()
        } label: {
            Image(systemName: symbol)
                .font(.appSystem(size: 15, weight: .medium))
                .foregroundColor(.white)
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// `defaultRate` is what `play()` uses, so the loop back to the start and
    /// a pause then play keep the speed. FullScreenVideoPlayer puts it back
    /// to 1× on close: the feed card shares this player.
    private func setRate(_ speed: Float) {
        onInteract?()
        rate = speed
        player.defaultRate = speed
        if player.timeControlStatus != .paused { player.rate = speed }
        VideoNowPlaying.shared.refresh()
    }

    private func skip(_ seconds: Double) {
        VideoNowPlaying.skip(player, by: seconds)
    }
}
