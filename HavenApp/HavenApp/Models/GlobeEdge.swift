import Foundation

/// How things fade at the globe's edge instead of popping. A face rolling
/// toward the rim and round the back fades and shrinks to the ember it
/// becomes there, and grows back coming over; a face losing its seat to a
/// neighbour cross-fades with the star it turns into; a live star or light
/// round the back dims rather than switching. Everything here is a smooth
/// function of depth (toward the viewer: about −1.6 at the back, 1.6 at the
/// front), so a turning globe never steps.
enum GlobeEdge {
    /// A face is whole above this depth...
    static let faceFull = 0.25
    /// ...and fully an ember below this one, where it loses its seat.
    static let faceGone = -0.1

    /// Smooth 0 → 1 between `a` and `b`, flat outside them.
    static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    /// How much of a face shows at `depth`: 1 at the front, 0 round the back.
    static func face(depth: Double) -> Double { smoothstep(faceGone, faceFull, depth) }

    /// A face's radius as it fades: it shrinks to three fifths, not to a
    /// point, so it lands on the ember rather than vanishing into it.
    static func faceRadius(_ r: Double, shown: Double) -> Double { r * (0.6 + 0.4 * shown) }

    /// Brightness of a live star, line or light at `depth`: full in front,
    /// a third round the back, smooth between.
    static func arc(depth: Double) -> Double { 0.35 + 0.65 * smoothstep(-0.45, 0.05, depth) }

    /// A seat's fade, eased toward `seated` over about a quarter second.
    /// Reduce Motion cuts.
    static func seat(_ current: Double, seated: Bool, dt: Double, reduceMotion: Bool) -> Double {
        let target = seated ? 1.0 : 0
        guard !reduceMotion else { return target }
        let next = current + (target - current) * (1 - exp(-dt * 12))
        return abs(target - next) < 0.01 ? target : next
    }
}
