import Foundation

/// The ranges Who Can Reach You offers, matched to what the relay accepts.
/// haven-go's Web of Trust only knows levels 0-3 and runs anything higher as
/// level 3 (pkg/wot/simple_in_memory.go), so a Follow Distance of 4 or 5 was
/// a setting that changed nothing.
enum RelayAccessLimits {
    static let followDistance = 1...3

    /// A value saved by an older build (up to 5) shows as what the relay uses.
    static func clampedFollowDistance(_ value: Int) -> Int {
        min(max(value, followDistance.lowerBound), followDistance.upperBound)
    }
}
