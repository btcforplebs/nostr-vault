import Foundation

/// The notification permission prompt: asked once, after you're in
/// (Logen 2026-11-05, PLANS/NV_FIRST_RUN_ENTRY_PLAN_2026_11_05.md item 4).
/// Not over setup's tour, not over a tutorial card or the Fill your feed
/// guide, not before any UI at launch, and on the Mac not before its window.
/// The push switch is set by the answer, not switched on before it.
///
/// Pure Foundation so MediaLogicTests can test it; PushNotificationService
/// (askWhenIn) drives it.
enum NotificationAsk {
    /// How long nothing else may be on screen before the prompt shows: a
    /// tutorial that ends can hand over to the next card within a moment.
    static let quietSeconds: TimeInterval = 2
    static let pollSeconds: TimeInterval = 0.5

    enum Action: Equatable {
        /// Already answered: just read the answer, never prompt.
        case alreadyAnswered
        /// Not in yet, or something is on screen: look again shortly.
        case wait
        /// Show the system prompt now.
        case ask
    }

    /// `undecided`: the system has never asked. `inApp`: setup is done and
    /// the app's own window is up and active. `busy`: a tutorial card or
    /// guide is showing or about to. `quietFor`: how long none has been.
    static func action(undecided: Bool, inApp: Bool, busy: Bool, quietFor: TimeInterval) -> Action {
        guard undecided else { return .alreadyAnswered }
        guard inApp, !busy, quietFor >= quietSeconds else { return .wait }
        return .ask
    }
}
