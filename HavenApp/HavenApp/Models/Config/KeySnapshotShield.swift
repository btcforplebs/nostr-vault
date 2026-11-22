import Foundation

/// When a secret key on screen must be covered so it never lands in the iOS
/// app-switcher picture. iOS takes that picture after the app resigns
/// active, and the switcher shows the live but inactive app before it, so
/// the cover goes on at "will resign active" and stays until the app is
/// active again. `.privacySensitive()` does not do this: it only redacts in
/// widgets and on the lock screen.
enum KeySnapshotShield {
    enum Moment: Equatable {
        case willResignActive
        case didEnterBackground
        case willEnterForeground
        case didBecomeActive
    }

    /// Whether the key is covered after `moment`. Coming back to the
    /// foreground is not enough: the app is still inactive (and the switcher
    /// may still be up) until it becomes active.
    static func covered(after moment: Moment) -> Bool {
        moment != .didBecomeActive
    }
}
