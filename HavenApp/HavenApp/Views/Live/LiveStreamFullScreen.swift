import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Full screen for a live stream: the video fills the screen sideways, with
/// the chat hidden or laid over its right side.
///
/// The phone app is held upright everywhere else, so landscape is allowed
/// only while this is on, the way the media viewer does it, and the phone
/// is turned back upright on the way out.
enum LiveFullScreen {
    static func enter() {
        #if os(iOS)
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        AppDelegate.allowLandscape = true
        turn(to: .landscapeRight)
        #endif
    }

    static func exit() {
        #if os(iOS)
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        AppDelegate.allowLandscape = false
        turn(to: .portrait)
        #endif
    }

    #if os(iOS)
    /// UIKit reads the allowed orientations again only when told to, from
    /// every controller up to the sheet on top; until then a request for
    /// landscape is refused against the old, upright-only answer.
    private static func turn(to orientations: UIInterfaceOrientationMask) {
        guard let scene = windowScene else { return }
        for window in scene.windows {
            var controller = window.rootViewController
            while let current = controller {
                current.setNeedsUpdateOfSupportedInterfaceOrientations()
                controller = current.presentedViewController
            }
        }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientations)) { error in
            #if DEBUG
            print("LiveFullScreen: orientation refused: \(error)")
            #endif
        }
    }

    private static var windowScene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.first as? UIWindowScene
    }
    #endif
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
