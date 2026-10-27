import Foundation

/// A notification fires only once what it points at can draw: the note is in
/// this device's relay, and the author's name and picture are loaded. Firing
/// on the bare relay marker used to put "Someone mentioned you" in the list,
/// a pill and a badge before the app could show who or what it was about.
///
/// Each wait is bounded, so a profile that never loads still notifies, just
/// as late as the bound allows instead of straight away.
///
/// Pure Foundation so MediaLogicTests can compile and test it directly; the
/// app supplies the checks (LocalNotificationService+Readiness).
enum NotificationReadiness {
    /// What has to be on screen before a `type` alert may fire.
    struct Needs: Equatable {
        /// The event itself, read from this device's relay.
        var note: Bool
        /// The author's profile (name, picture URL).
        var profile: Bool
        /// The author's picture, decoded and cached.
        var avatar: Bool
    }

    static func needs(type: String) -> Needs {
        switch type {
        case "mention", "reply", "quote", "reaction", "repost", "zap":
            return Needs(note: true, profile: true, avatar: true)
        case "dm", "giftwrap", "follow":
            // A DM's text comes from the inbox once it decrypts, and a follow
            // has no note: the person is what draws.
            return Needs(note: false, profile: true, avatar: true)
        default:
            // The catch-up summary and the folded strangers' count name nobody.
            return Needs(note: false, profile: false, avatar: false)
        }
    }

    /// How long one alert may wait for the author's profile.
    static let profileTimeout: TimeInterval = 3
    /// How long it may wait for the picture after the profile names one.
    static let avatarTimeout: TimeInterval = 2
    /// How long it may wait for the note to be readable from the relay.
    static let noteTimeout: TimeInterval = 3
    static let pollInterval: TimeInterval = 0.25

    /// Asks `isReady` until it answers true or `timeout` passes. True when it
    /// became ready, false when the wait ran out.
    static func wait(timeout: TimeInterval, interval: TimeInterval = pollInterval,
                     isReady: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if await isReady() { return true }
            guard Date() < deadline else { return false }
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }
}
