import Foundation

/// The iPhone mesh engine across short trips out of the app (Logen
/// 2026-11-14, routing audit fix 1). Leaving the app used to stop the
/// engine at once and coming back started it cold: on one iPhone that was
/// 421 starts in 35 h, each one paying the relays, the seeds and the tree
/// again. Now a trip shorter than `grace` keeps the engine as it is.
///
/// `grace` stays under the ~30 s background task iOSAppDelegate takes, so
/// the engine is stopped cleanly before iOS can freeze the app. An engine
/// iOS froze anyway comes back with its UDP socket gone ("Socket is not
/// connected", os error 57, once a second until a restart): a return later
/// than `grace` finds it, and it starts fresh instead of limping on.
enum MeshKeepWarm {
    /// How long the engine outlives the app leaving the screen.
    static let grace: TimeInterval = 25

    enum Return: Equatable {
        /// Back within the grace: the engine is kept as it is.
        case keep
        /// Back after the grace: if the engine is still marked up, iOS froze
        /// it before the grace could stop it. Stop it and start fresh.
        case restartIfUp
        /// Not away (a first activation, or a second notice of the same return).
        case none
    }

    /// One trip away at a time. Pure: the service feeds it the times.
    struct Clock: Equatable {
        private(set) var awaySince: Date?
        /// Bumped by each trip, so a grace timer from an earlier trip never
        /// stops the engine during a later one.
        private(set) var trip = 0

        init() {}

        /// The app left the screen. The trip to schedule the grace end for,
        /// or nil when this trip was already counted (two observers, one trip).
        mutating func left(at now: Date) -> Int? {
            guard awaySince == nil else { return nil }
            awaySince = now
            trip += 1
            return trip
        }

        /// The grace timer for `trip` fired: whether the engine stops now
        /// (still away on that same trip).
        func graceEnded(trip: Int) -> Bool {
            awaySince != nil && trip == self.trip
        }

        /// The app is back on screen.
        mutating func returned(at now: Date) -> Return {
            guard let since = awaySince else { return .none }
            awaySince = nil
            return now.timeIntervalSince(since) < MeshKeepWarm.grace ? .keep : .restartIfUp
        }
    }
}
