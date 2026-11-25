import SwiftUI
import simd

/// Draws the globe's outer rings (`TrustMapOuter`) behind the stars: one
/// circle per hop past your circle, a dot on it for each of its best-ranked
/// people, fainter the further out (`TrustMapOuter.fade`), and its hop count
/// where the ring crosses the screen. Faint, with
/// no dots, when there is no rank. The rings sit round the middle of the
/// screen and grow with the camera's zoom, so they stay outside the globe.
/// Android twin: `ui/components/trustweb/GlobeOuterRings.kt`.
enum GlobeOuterRings {
    /// The inner globe's outline radius on screen (`GlobeCamera.unit`).
    static func outline(size: CGSize, zoom: Double, phone: Bool) -> Double {
        let r = TrustMap.ringRadius, d = GlobeCamera.distance / zoom
        guard d > r else { return .infinity }
        return GlobeCamera.unit(for: size, phone: phone) * r / (d * d - r * r).squareRoot()
    }

    /// Where on its circle a person's dot sits: from their key, so it never moves.
    static func angle(_ pubkey: String) -> Double { GlobeHazeField.hash(pubkey).angle }

    /// `level` is how far a Hop layer has zoomed out (`GlobeRingZoom`):
    /// 0 draws the rings flat round the full globe. Past it the picked ring
    /// becomes a sphere of its own (`drawSpheres`), so its flat circle and
    /// dots fade out as `GlobeRingZoom.sphere` comes in; the rings past it
    /// go. Only the hop label stays, on the sphere's top.
    static func draw(_ outer: TrustMapOuter, in context: inout GraphicsContext, size: CGSize,
                     zoom: Double, phone: Bool, ink: GlobeInk, level: Double = 0) {
        guard !outer.rings.isEmpty else { return }
        let base = outline(size: size, zoom: zoom, phone: phone)
        guard base.isFinite else { return }
        let half = Double(min(size.width, size.height)) / 2
        let faint = outer.isFaint
        for ring in outer.rings {
            let shown = GlobeRingZoom.visibility(hop: ring.hop, level: level)
            guard shown > 0.01 else { continue }
            let picked = GlobeRingZoom.emphasis(hop: ring.hop, level: level)
            let flat = faint ? 1 : 1 - GlobeRingZoom.sphere(hop: ring.hop, level: level)
            let at = place(ring.hop, level: level, base: base, size: size, half: half), r = at.r, c = at.centre
            let fade = (faint ? 1 : fadeFor(ring.hop, picked: picked)) * shown
            if flat > 0.01 {
                let circle = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
                context.stroke(circle, with: .color(ink.haze.opacity((faint ? 0.10 : 0.28 * max(fade, 0.5 * shown)) * flat)),
                               style: StrokeStyle(lineWidth: faint ? 0.8 : 1.1, dash: faint ? [3, 6] : []))
                if !faint {
                    let dot = 1.6
                    var dots = Path()
                    for key in ring.top {
                        let a = angle(key)
                        let p = CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
                        dots.addEllipse(in: CGRect(x: p.x - dot, y: p.y - dot, width: dot * 2, height: dot * 2))
                    }
                    context.fill(dots, with: .color(ink.star.opacity(0.75 * fade * flat)))
                }
            }
            // A ring that sank under a later pick loses its label.
            let sunk = GlobeRingZoom.inside(hop: ring.hop, level: level)
            if sunk < 0.99, let at = labelPoint(r: r, mid: c, size: size) {
                let text = Text(faint ? "\(ring.hop) hops" : TrustMapOuter.chipText(ring))
                    .font(.system(size: 10 + 2 * picked, weight: .semibold))
                    .foregroundColor(ink.label.opacity((faint ? 0.35 : 0.7 * max(fade, 0.5)) * shown * (1 - sunk)))
                context.draw(text, at: at, anchor: .bottomTrailing)
            }
        }
    }

    /// The picked hop's sphere, and any picked before it that sank under it
    /// (`GlobeHopSphere`), turned by the inner globe's camera `turn`. Drawn
    /// over the inner globe: that has sunk away underneath.
    static func drawSpheres(_ outer: TrustMapOuter, in context: inout GraphicsContext, size: CGSize,
                            zoom: Double, phone: Bool, ink: GlobeInk, level: Double,
                            turn: simd_double3x3, pole: SIMD3<Double>, pictures: Set<String>,
                            focus: String? = nil) {
        GlobeHopSphere.clearTargets()
        guard level > 0.001, !outer.isFaint else { return }
        let base = outline(size: size, zoom: zoom, phone: phone)
        guard base.isFinite else { return }
        let half = Double(min(size.width, size.height)) / 2
        // Inner first, so the picked one is drawn over what sank.
        for ring in outer.rings {
            let sphere = GlobeRingZoom.sphere(hop: ring.hop, level: level)
            let shown = GlobeRingZoom.visibility(hop: ring.hop, level: level) * sphere
            guard shown > 0.01 else { continue }
            let picked = GlobeRingZoom.emphasis(hop: ring.hop, level: level)
            let at = place(ring.hop, level: level, base: base, size: size, half: half)
            GlobeHopSphere.draw(ring, centre: at.centre, r: at.r, shown: shown * fadeFor(ring.hop, picked: picked),
                                picked: picked, turn: turn, pole: pole, pictures: pictures, focus: focus, in: &context, ink: ink)
        }
    }

    /// A ring's centre and radius at `level`, sunk when it is inside the picked one.
    private static func place(_ hop: Int, level: Double, base: Double, size: CGSize,
                              half: Double) -> (centre: CGPoint, r: Double) {
        let r = hop < TrustMapOuter.firstHop
            ? GlobeRingZoom.innerOutline(level: level, outline: base)
            : GlobeRingZoom.radius(hop: hop, level: level, outline: base, half: half)
        let (drop, scale) = GlobeRingZoom.sink(hop: hop, level: level, half: half)
        return (CGPoint(x: size.width / 2, y: size.height / 2 + drop), r * scale)
    }

    /// The picked ring comes up to full strength, whatever its hop.
    private static func fadeFor(_ hop: Int, picked: Double) -> Double {
        let ringFade = TrustMapOuter.fade(hop: hop)
        return ringFade + (1 - ringFade) * picked
    }

    /// Up and to the right on the ring, where it is still on screen: the
    /// top of the circle when it fits, else where it crosses the right edge.
    private static func labelPoint(r: Double, mid: CGPoint, size: CGSize) -> CGPoint? {
        let inset = 14.0
        let dx = min(r * 0.5, Double(size.width) / 2 - inset)
        guard dx > 0, r > dx else { return nil }
        let y = Double(mid.y) - (r * r - dx * dx).squareRoot() - 3
        // Clear of the status bar and the WOT tab's top bar.
        guard y > 120 else { return nil }
        return CGPoint(x: Double(mid.x) + dx, y: y)
    }
}
