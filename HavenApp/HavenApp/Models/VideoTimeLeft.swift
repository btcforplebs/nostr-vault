import Foundation

/// The small "time left" label on a clip playing in the feed, like the
/// big player's clock but counting down, so a glance says how long it is.
enum VideoTimeLeft {
    static func label(elapsed: Double, duration: Double) -> String? {
        guard duration.isFinite, duration > 0, elapsed.isFinite else { return nil }
        let left = Int(max(0, duration - max(0, elapsed)).rounded(.up))
        let h = left / 3600, m = (left % 3600) / 60, s = left % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
