import SwiftUI

/// Draws the globe's outer rings (`TrustMapOuter`) behind the stars: one
/// circle per hop past your circle, a dot on it for each of its best-ranked
/// people, and its hop count where the ring crosses the screen. Faint, with
/// no dots, when there is no rank. The rings sit round the middle of the
/// screen and grow with the camera's zoom, so they stay outside the globe.
/// Android twin: `ui/components/trustweb/GlobeOuterRings.kt`.
enum GlobeOuterRings {
    /// Ring radius against the inner globe's outline, for the first outer
    /// hop; each hop after it sits `step` further out.
    static let first = 1.72
    static let step = 0.26

    /// The inner globe's outline radius on screen (`GlobeCamera.unit`).
    static func outline(size: CGSize, zoom: Double, phone: Bool) -> Double {
        let r = TrustMap.ringRadius, d = GlobeCamera.distance / zoom
        guard d > r else { return .infinity }
        return GlobeCamera.unit(for: size, phone: phone) * r / (d * d - r * r).squareRoot()
    }

    static func radius(hop: Int, outline: Double) -> Double {
        outline * (first + step * Double(hop - TrustMapOuter.firstHop))
    }

    /// Where on its circle a person's dot sits: from their key, so it never moves.
    static func angle(_ pubkey: String) -> Double {
        let head = pubkey.utf8.prefix(8).reduce(UInt64(0)) { $0 &* 31 &+ UInt64($1) }
        return Double(head % 3600) / 3600 * 2 * .pi
    }

    static func draw(_ outer: TrustMapOuter, in context: inout GraphicsContext, size: CGSize,
                     zoom: Double, phone: Bool, ink: GlobeInk) {
        guard !outer.rings.isEmpty else { return }
        let base = outline(size: size, zoom: zoom, phone: phone)
        guard base.isFinite else { return }
        let mid = CGPoint(x: size.width / 2, y: size.height / 2)
        let faint = outer.isFaint
        for ring in outer.rings {
            let r = radius(hop: ring.hop, outline: base)
            let circle = Path(ellipseIn: CGRect(x: mid.x - r, y: mid.y - r, width: r * 2, height: r * 2))
            context.stroke(circle, with: .color(ink.haze.opacity(faint ? 0.10 : 0.28)),
                           style: StrokeStyle(lineWidth: faint ? 0.8 : 1.1, dash: faint ? [3, 6] : []))
            if !faint {
                var dots = Path()
                for key in ring.top {
                    let a = angle(key)
                    let p = CGPoint(x: mid.x + r * cos(a), y: mid.y + r * sin(a))
                    dots.addEllipse(in: CGRect(x: p.x - 1.6, y: p.y - 1.6, width: 3.2, height: 3.2))
                }
                context.fill(dots, with: .color(ink.star.opacity(0.75)))
            }
            if let at = labelPoint(r: r, mid: mid, size: size) {
                let text = Text(faint ? "\(ring.hop) hops" : TrustMapOuter.chipText(ring))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(ink.label.opacity(faint ? 0.35 : 0.7))
                context.draw(text, at: at, anchor: .bottomTrailing)
            }
        }
    }

    /// Up and to the right on the ring, where it is still on screen: the
    /// top of the circle when it fits, else where it crosses the right edge.
    private static func labelPoint(r: Double, mid: CGPoint, size: CGSize) -> CGPoint? {
        let inset = 14.0
        let dx = min(r * 0.5, Double(size.width) / 2 - inset)
        guard dx > 0, r > dx else { return nil }
        let y = Double(mid.y) - (r * r - dx * dx).squareRoot() - 3
        guard y > 40 else { return nil }
        return CGPoint(x: Double(mid.x) + dx, y: y)
    }
}
