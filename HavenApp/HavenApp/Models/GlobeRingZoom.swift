import CoreGraphics
import Foundation

/// The WOT tab's Hop 3, Hop 4 and Hop 5 layers zoom your own globe out to
/// that outer ring: the inner spheres shrink toward the middle and fade, the
/// rings inside the picked one close up around them, and the picked ring
/// grows to fill the frame (Logen 2026-11-24, "best visual effort").
///
/// `level` is a continuous zoom: 0 is your circle (Everyone, Following,
/// Vouched), 1 is Hop 3, 2 is Hop 4, 3 is Hop 5. The globe eases it from
/// pick to pick, so every value in between is drawn and it animates both
/// ways. Pure math, so the tests and the Android twin
/// (`data/model/GlobeRingZoom.kt`) can pin it.
enum GlobeRingZoom {
    /// Ring radius against the inner globe's outline at level 0, for the
    /// first outer hop; each hop after it sits `step` further out.
    static let first = 1.72
    static let step = 0.26

    /// The deepest level: Hop 5.
    static let maxLevel = 3

    /// How big the inner globe is drawn at each whole level.
    static let innerScales: [Double] = [1, 0.36, 0.25, 0.18]
    /// How strongly the inner globe is drawn at each whole level: faded,
    /// never gone, so the lines still have somewhere to land.
    static let innerAlphas: [Double] = [1, 0.6, 0.5, 0.42]
    /// The picked ring's radius as a share of half the frame's short side.
    static let fit = 0.84
    /// Rings inside the picked one are drawn this strongly.
    static let insideAlpha = 0.6
    /// At most this many of the picked ring's people get a line to the
    /// person one ring in who links them to you (`TrustRankCopy.GlobePerson.via`).
    /// 120 drew a web of chords right across the ring and over the shrunk
    /// globe (a via's place on its ring has nothing to do with yours), so
    /// only the best 40 get one, faint.
    static let maxLinks = 40

    /// The zoom level a hop layer asks for; nil (your circle) is 0.
    // MARK: Sink (Logen 2026-11-24)

    /// Everything inside the picked ring (the inner globe, and the rings
    /// between it and the picked one) sinks down and gets smaller, so it
    /// reads as pulling back into space; the picked ring and its haze
    /// (`GlobeHazeField`) stay centred. How far down, as a share of half the
    /// frame's short side, at each whole level.
    static let sinkDrops: [Double] = [0, 0.34, 0.36, 0.38]
    /// How much smaller what sinks is drawn, on top of `innerScales`.
    static let sinkScales: [Double] = [1, 0.8, 0.74, 0.68]

    /// How much `hop`'s ring sinks (0 to 1): the inner globe (hop 2 and
    /// in) once any hop is picked, an outer ring once a hop past it is.
    static func inside(hop: Int, level: Double) -> Double {
        let (lo, hi, t) = bracket(level)
        let a = inside(hop: hop, whole: lo), b = inside(hop: hop, whole: hi)
        return a + (b - a) * t
    }

    /// Where `hop`'s ring is drawn at `level`: its centre `drop` points below
    /// the frame's middle, and `scale` times its radius.
    static func sink(hop: Int, level: Double, half: Double) -> (drop: Double, scale: Double) {
        let a = inside(hop: hop, level: level)
        return (a * lerp(sinkDrops, level) * half, 1 - a * (1 - lerp(sinkScales, level)))
    }

    /// The inner globe's drawing transform at `level`: shrunk (`innerScale`
    /// times the sink's scale) round the frame's middle, then dropped.
    static func innerTransform(level: Double, size: CGSize) -> CGAffineTransform {
        let half = Double(min(size.width, size.height)) / 2
        let (drop, scale) = sink(hop: TrustMapOuter.firstHop - 1, level: level, half: half)
        let s = innerScale(level) * scale
        let mx = Double(size.width) / 2, my = Double(size.height) / 2
        return CGAffineTransform(translationX: -mx, y: -my)
            .concatenating(CGAffineTransform(scaleX: s, y: s))
            .concatenating(CGAffineTransform(translationX: mx, y: my + drop))
    }

    private static func inside(hop: Int, whole: Int) -> Double {
        whole > 0 && hop < TrustMapOuter.firstHop + whole - 1 ? 1 : 0
    }

    static func level(hop: Int?) -> Double {
        guard let hop else { return 0 }
        return Double(min(maxLevel, max(1, hop - TrustMapOuter.firstHop + 1)))
    }

    static func innerScale(_ level: Double) -> Double { lerp(innerScales, level) }
    static func innerAlpha(_ level: Double) -> Double { lerp(innerAlphas, level) }

    /// A ring's radius on screen. `outline` is the inner globe's outline
    /// radius unzoomed (`GlobeOuterRings.outline`); `half` is half the
    /// frame's short side.
    static func radius(hop: Int, level: Double, outline: Double, half: Double) -> Double {
        let (lo, hi, t) = bracket(level)
        let a = radius(hop: hop, whole: lo, outline: outline, half: half)
        let b = radius(hop: hop, whole: hi, outline: outline, half: half)
        return a + (b - a) * t
    }

    /// The inner globe's outline on screen at `level`: where hop 3's links land.
    static func innerOutline(level: Double, outline: Double) -> Double {
        outline * innerScale(level)
    }

    /// How strongly `hop`'s ring is drawn at `level` (0 to 1): all of them
    /// at 0, then the picked ring full, the ones inside it back, and the
    /// ones past it gone.
    static func visibility(hop: Int, level: Double) -> Double {
        let (lo, hi, t) = bracket(level)
        let a = visibility(hop: hop, whole: lo), b = visibility(hop: hop, whole: hi)
        return a + (b - a) * t
    }

    /// How much `hop`'s ring is the picked one (0 to 1): it is drawn at full
    /// strength with bigger dots, and its people get their lines.
    static func emphasis(hop: Int, level: Double) -> Double {
        let (lo, hi, t) = bracket(level)
        let a = emphasis(hop: hop, whole: lo), b = emphasis(hop: hop, whole: hi)
        return a + (b - a) * t
    }

    // MARK: Whole levels

    private static func radius(hop: Int, whole: Int, outline: Double, half: Double) -> Double {
        let outward = Double(hop - TrustMapOuter.firstHop)
        guard whole > 0 else { return outline * (first + step * outward) }
        // Hop 2 (the inner globe) at the shrunk outline, the picked ring at
        // the fit, and the rings between evenly spaced.
        let inner = outline * innerScales[whole]
        let fitted = fit * half
        let gap = (fitted - inner) / Double(whole)
        return inner + gap * (outward + 1)
    }

    private static func visibility(hop: Int, whole: Int) -> Double {
        guard whole > 0 else { return 1 }
        let picked = TrustMapOuter.firstHop + whole - 1
        return hop == picked ? 1 : hop < picked ? insideAlpha : 0
    }

    private static func emphasis(hop: Int, whole: Int) -> Double {
        whole > 0 && hop == TrustMapOuter.firstHop + whole - 1 ? 1 : 0
    }

    // MARK: Easing between whole levels

    private static func bracket(_ level: Double) -> (Int, Int, Double) {
        let z = min(Double(maxLevel), max(0, level.isFinite ? level : 0))
        let lo = Int(z.rounded(.down))
        return (lo, min(maxLevel, lo + 1), z - Double(lo))
    }

    private static func lerp(_ table: [Double], _ level: Double) -> Double {
        let (lo, hi, t) = bracket(level)
        return table[lo] + (table[hi] - table[lo]) * t
    }
}
