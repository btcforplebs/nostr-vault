import SwiftUI

/// Covers a secret key while the app is not active, so the key never shows
/// in the iOS app-switcher card or the picture iOS saves for it
/// (KeySnapshotShield). From the app notifications, not `scenePhase`: the iOS
/// app hosts SwiftUI from a UIKit scene delegate, where `scenePhase` never
/// reads `.active`. A no-op on the Mac, which has no switcher picture.
struct KeySnapshotCover: ViewModifier {
    @State private var covered = false

    func body(content: Content) -> some View {
        #if os(iOS)
        // Not drawn at all while covered, rather than drawn under a patch:
        // the row's own background shows, in either colour scheme.
        content
            .opacity(covered ? 0 : 1)
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                apply(.willResignActive)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                apply(.didEnterBackground)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                apply(.willEnterForeground)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                apply(.didBecomeActive)
            }
        #else
        content
        #endif
    }

    private func apply(_ moment: KeySnapshotShield.Moment) {
        // No animation: the cover has to be on screen before iOS takes the picture.
        var plain = Transaction()
        plain.disablesAnimations = true
        withTransaction(plain) { covered = KeySnapshotShield.covered(after: moment) }
    }
}

extension View {
    /// Hide this secret key from the iOS app switcher (KeySnapshotCover).
    func keySnapshotCover() -> some View {
        modifier(KeySnapshotCover())
    }
}
