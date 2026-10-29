import Foundation

/// What iPhone kiosk mode does once strangers have downloaded the serve
/// limit. The engine stops serving strangers at the limit by itself. Kiosk
/// mode stays on, and My Devices keep their full access; strangers are served
/// again at the time `KioskDailyBudget` gives (tomorrow, once today's budget
/// is spent), so a stranger who uses up the limit with throwaway mesh keys
/// cannot keep the kiosk off. Kept free of UIKit so MediaLogicTests can check it.
enum KioskCapPause {
    /// The serve limit sent to the engine. The picker's 0 means no limit, but
    /// the engine reads 0 as its 1 GB default, so no limit goes as the largest value.
    static func engineServeLimit(_ limit: Int64) -> Int64 { limit == 0 ? .max : limit }

    enum Step: Equatable {
        case none
        /// The engine reported the limit: stay on, share again at this time.
        case pause(until: Date)
        /// The pause is over: start a new sharing session.
        case resume
    }

    /// `shareAgainAt` is asked only when the limit is newly reached. Sharing
    /// again is a fresh engine start, so a stale limit report cannot outlive it.
    static func step(capReached: Bool, pausedUntil: Date?, now: Date, shareAgainAt: () -> Date) -> Step {
        guard let pausedUntil else {
            return capReached ? .pause(until: shareAgainAt()) : .none
        }
        return now >= pausedUntil ? .resume : .none
    }
}
