import SwiftUI

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
    /// 0 draws the rings round the full globe; past it the picked ring
    /// fills the frame with its haze (`GlobeHaze`) behind its dots, the rings
    /// inside it close in on the shrunk globe and sink with it
    /// (`GlobeRingZoom.sink`), and the picked ring's people get a line to
    /// their link one ring in.
    static func draw(_ outer: TrustMapOuter, in context: inout GraphicsContext, size: CGSize,
                     zoom: Double, phone: Bool, ink: GlobeInk, level: Double = 0) {
        guard !outer.rings.isEmpty else { return }
        let base = outline(size: size, zoom: zoom, phone: phone)
        guard base.isFinite else { return }
        let mid = CGPoint(x: size.width / 2, y: size.height / 2)
        let half = Double(min(size.width, size.height)) / 2
        let faint = outer.isFaint
        // A ring's centre and radius, sunk when it is inside the picked one.
        func place(_ hop: Int) -> (centre: CGPoint, r: Double) {
            let r = hop < TrustMapOuter.firstHop
                ? GlobeRingZoom.innerOutline(level: level, outline: base)
                : GlobeRingZoom.radius(hop: hop, level: level, outline: base, half: half)
            let (drop, scale) = GlobeRingZoom.sink(hop: hop, level: level, half: half)
            return (CGPoint(x: mid.x, y: mid.y + drop), r * scale)
        }
        func point(_ key: String, _ at: (centre: CGPoint, r: Double)) -> CGPoint {
            let a = angle(key)
            return CGPoint(x: at.centre.x + at.r * cos(a), y: at.centre.y + at.r * sin(a))
        }
        for ring in outer.rings {
            let shown = GlobeRingZoom.visibility(hop: ring.hop, level: level)
            guard shown > 0.01 else { continue }
            let picked = GlobeRingZoom.emphasis(hop: ring.hop, level: level)
            let at = place(ring.hop), r = at.r, c = at.centre
            // The picked ring comes up to full strength, whatever its hop.
            let ringFade = TrustMapOuter.fade(hop: ring.hop)
            let fade = (faint ? 1 : ringFade + (1 - ringFade) * picked) * shown
            // Its line steps back as its haze comes in.
            let line = ring.haze.isEmpty || faint ? 1 : 1 - 0.55 * picked
            let circle = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            context.stroke(circle, with: .color(ink.haze.opacity(((faint ? 0.10 : 0.28 * max(fade, 0.5 * shown)) + 0.14 * picked) * line)),
                           style: StrokeStyle(lineWidth: (faint ? 0.8 : 1.1) + 0.5 * picked, dash: faint ? [3, 6] : []))
            if !faint {
                GlobeHaze.draw(ring, alpha: picked, mid: c, r: r, ref: GlobeRingZoom.fit * half, in: &context, ink: ink)
                if picked > 0.01 { drawLinks(ring, alpha: picked, from: at, to: place(ring.hop - 1),
                                             innerDots: outer.rings.first { $0.hop == ring.hop - 1 }.map { Set($0.top) },
                                             point: point, in: &context, ink: ink) }
                let dot = 1.6 * (1 + 0.5 * picked)
                var dots = Path()
                for key in ring.top {
                    let p = point(key, at)
                    dots.addEllipse(in: CGRect(x: p.x - dot, y: p.y - dot, width: dot * 2, height: dot * 2))
                }
                context.fill(dots, with: .color(ink.star.opacity(0.75 * fade)))
            }
            if let at = labelPoint(r: r, mid: c, size: size) {
                let text = Text(faint ? "\(ring.hop) hops" : TrustMapOuter.chipText(ring))
                    .font(.system(size: 10 + 2 * picked, weight: .semibold))
                    .foregroundColor(ink.label.opacity((faint ? 0.35 : 0.7 * max(fade, 0.5)) * shown))
                context.draw(text, at: at, anchor: .bottomTrailing)
            }
        }
    }

    /// Lines from the picked ring's best people to who links them in: on
    /// the ring inside, or for Hop 3 on the shrunk globe's edge. Faint and
    /// capped (`GlobeRingZoom.maxLinks`) so they read as threads, not a fan.
    /// On an outer ring a line is drawn only when its far end is a dot
    /// there (`innerDots`), so none ends in empty space.
    private static func drawLinks(_ ring: TrustMapOuter.Ring, alpha: Double, from r: (centre: CGPoint, r: Double),
                                  to inner: (centre: CGPoint, r: Double), innerDots: Set<String>?,
                                  point: (String, (centre: CGPoint, r: Double)) -> CGPoint,
                                  in context: inout GraphicsContext, ink: GlobeInk) {
        var lines = Path()
        for key in ring.top.prefix(GlobeRingZoom.maxLinks) {
            guard let via = ring.via[key], innerDots?.contains(via) ?? true else { continue }
            lines.move(to: point(key, r))
            lines.addLine(to: point(via, inner))
        }
        context.stroke(lines, with: .color(ink.haze.opacity(0.12 * alpha)), lineWidth: 0.6)
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
