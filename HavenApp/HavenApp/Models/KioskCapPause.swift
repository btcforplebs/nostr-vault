import Foundation

/// What iPhone kiosk mode does once the mesh has downloaded one session's
/// serve limit. The engine stops serving at the limit by itself. Kiosk mode
/// stays on and shares again after a cool-down, so a stranger who uses up the
/// limit with throwaway mesh keys cannot keep the kiosk off. Kept free of
/// UIKit so MediaLogicTests can check it.
enum KioskCapPause {
    static let coolDown: TimeInterval = 60 * 60

    enum Step: Equatable {
        case none
        /// The engine reported the limit: stay on, share again at this time.
        case pause(until: Date)
        /// The cool-down is over: start a new sharing session.
        case resume
    }

    /// `resuming` is a share-again call still in flight. The engine keeps
    /// reporting the limit until that call lands, so it must not pause again.
    static func step(capReached: Bool, pausedUntil: Date?, resuming: Bool, now: Date) -> Step {
        if resuming { return .none }
        guard let pausedUntil else {
            return capReached ? .pause(until: now.addingTimeInterval(coolDown)) : .none
        }
        return now >= pausedUntil ? .resume : .none
    }
}
