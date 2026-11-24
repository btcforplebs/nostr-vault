import CoreGraphics
import Foundation

/// The haze a zoomed-out Hop 3 or Hop 4 ring shows (Logen 2026-11-24): the
/// ring's people ranked after its top 300 (`TrustRankCopy.haze`), as faint
/// dots that cannot be tapped. Each dot's angle comes from its key, so it
/// never moves; its distance from the ring's centre comes from its rank,
/// the best nearest the centre and the lowest drifting out past the line,
/// with a small jitter from the key. Positions are worked out once per ring
/// in unit space (the ring's radius is 1); each frame only scales them.
/// Pure math, so the tests and the Android twin can pin it.
enum GlobeHazeField {
    /// The best haze dot's distance from the centre, against the ring's radius.
    static let nearest = 0.42
    /// The lowest one's.
    static let furthest = 1.12
    /// Jitter either way, against the ring's radius.
    static let jitter = 0.04

    /// Unit-space positions for `keys`, best first.
    static func positions(_ keys: [String]) -> [CGPoint] {
        let n = Double(max(keys.count, 1))
        return keys.enumerated().map { i, key in
            let (angle, wobble) = hash(key)
            // sqrt spreads the dots evenly over the area, not bunched in the middle.
            let u = ((Double(i) + 0.5) / n).squareRoot()
            let r = nearest + (furthest - nearest) * u + jitter * (2 * wobble - 1)
            return CGPoint(x: r * cos(angle), y: r * sin(angle))
        }
    }

    /// The angle `GlobeOuterRings.angle` gives the same key, and a 0-1 wobble
    /// from the key's next 8 characters.
    static func hash(_ key: String) -> (angle: Double, wobble: Double) {
        let bytes = Array(key.utf8)
        func fold(_ part: ArraySlice<UInt8>) -> UInt64 { part.reduce(UInt64(0)) { $0 &* 31 &+ UInt64($1) } }
        let head = fold(bytes.prefix(8)), next = fold(bytes.dropFirst(8).prefix(8))
        return (Double(head % 3600) / 3600 * 2 * .pi, Double(next % 1000) / 1000)
    }
}
