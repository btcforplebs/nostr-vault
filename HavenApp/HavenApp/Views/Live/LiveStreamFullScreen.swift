import SwiftUI

/// Full screen for a live stream: the video fills the screen sideways, with
/// the chat hidden or laid over its right side.
///
/// The phone app is held upright everywhere else, so landscape is allowed
/// only while this is on, the way the media viewers do it, and the phone
/// is turned back upright once nothing else holds it sideways.
enum LiveFullScreen {
    /// Shares `LandscapeAllowance` with the media viewers, so a photo opened
    /// from live full screen and closed again leaves live sideways.
    @MainActor
    static func enter() {
        LandscapeAllowance.open()
        LandscapeAllowance.turnSideways()
    }

    @MainActor
    static func exit() {
        LandscapeAllowance.close()
    }
}

/// A round control over the video: dark disc, white glyph, 44 pt target.
struct LiveVideoOverlayButton: View {
    let systemImage: String
    let label: String
    var isOn = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.appSystem(size: 15, weight: .bold))
                .foregroundColor(isOn ? .havenPurple : .white)
                .frame(width: 36, height: 36)
                .background(Circle().fill(isOn ? Color.white : Color.black.opacity(0.45)))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
