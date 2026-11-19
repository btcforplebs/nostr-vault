import Foundation

/// The full-screen player's extra controls, as rules: speed, skip, and what
/// a live stream leaves out (Logen 2026-11-19: keep our player, add the
/// missing bits). Views in Views/VideoPlayer/VideoExtraControls.swift.
enum VideoPlayerControls {
    /// Speeds offered, in menu order.
    static let speeds: [Float] = [0.5, 1, 1.25, 1.5, 2]

    /// How far the skip buttons and the lock screen's skip go.
    static let skipSeconds: Double = 10

    /// "1×", "1.25×", "0.5×".
    static func speedLabel(_ rate: Float) -> String {
        let text = rate == rate.rounded() ? String(Int(rate)) : String(format: "%g", rate)
        return "\(text)×"
    }

    /// Where a skip of `by` seconds from `current` lands: never before the
    /// start, and never past the end when the length is known.
    static func skipTarget(current: Double, by: Double, duration: Double?) -> Double {
        let target = max(0, (current.isFinite ? current : 0) + by)
        guard let duration, duration.isFinite, duration > 0 else { return target }
        return min(target, duration)
    }

    /// A live stream has no speed or skip: it plays at the broadcast's edge.
    static func showsSpeedAndSkip(isLive: Bool) -> Bool { !isLive }

}
