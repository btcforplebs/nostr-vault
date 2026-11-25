import Foundation

/// A key's fixed angle round a flat outer ring (`GlobeOuterRings.angle`) and
/// a 0-1 wobble, both from the key alone, so a dot never moves. The picked
/// hop's sphere (`GlobeSphereField`) uses the wobble to break up its spiral.
/// Pure math, so the tests and the Android twin can pin it.
enum GlobeHazeField {
    /// The angle from the key's first 8 characters, and a 0-1 wobble from
    /// its next 8.
    static func hash(_ key: String) -> (angle: Double, wobble: Double) {
        let bytes = Array(key.utf8)
        func fold(_ part: ArraySlice<UInt8>) -> UInt64 { part.reduce(UInt64(0)) { $0 &* 31 &+ UInt64($1) } }
        let head = fold(bytes.prefix(8)), next = fold(bytes.dropFirst(8).prefix(8))
        return (Double(head % 3600) / 3600 * 2 * .pi, Double(next % 1000) / 1000)
    }
}
