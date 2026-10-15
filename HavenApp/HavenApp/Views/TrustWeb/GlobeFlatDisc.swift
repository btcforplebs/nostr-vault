import SwiftUI

/// The map view's ground marks: no border, just a faint dashed ring where one
/// zone (your follows, Discover, Global) gives way to the next, under the
/// same stars, faces and lines as the globe.
struct GlobeFlatDisc {
    /// Where you sit on screen: the middle of the network.
    let center: CGPoint
    /// Points per map unit, zoom included.
    let unit: Double
    /// 0 to 1 while the globe flattens.
    let opacity: Double
    let hazeColor: Color

    func draw(_ context: inout GraphicsContext) {
        guard opacity > 0.01 else { return }
        let zones = GlobeFlat.zones
        for i in 1..<(zones.count - 2) {
            let r = (zones[i].outer + zones[i + 1].inner) / 2 * GlobeFlat.rim * unit
            context.stroke(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)),
                           with: .color(hazeColor.opacity(0.10 * opacity)),
                           style: StrokeStyle(lineWidth: 0.6, dash: [2, 6]))
        }
    }

    /// The web's lines: you to each person you follow, all in one faint
    /// stroke, and a little brighter to the ones drawn as faces. Only real
    /// follows are drawn, so every line is a connection that exists. Only
    /// the lines to people on screen (and to faces whose line crosses it)
    /// are drawn, so a big map draws only what shows.
    static func links(_ context: inout GraphicsContext, from core: CGPoint, to stars: [CGPoint],
                      faces: [CGPoint], in view: CGRect, color: Color, opacity: Double) {
        guard opacity > 0.01, !stars.isEmpty || !faces.isEmpty else { return }
        func shows(_ p: CGPoint) -> Bool {
            view.intersects(CGRect(x: min(core.x, p.x), y: min(core.y, p.y),
                                   width: abs(core.x - p.x) + 1, height: abs(core.y - p.y) + 1))
        }
        var faint = Path(), strong = Path()
        // Plain follows only when they are on screen: a thousand lines from
        // far off would only make a starburst.
        for p in stars where view.contains(p) { faint.move(to: core); faint.addLine(to: p) }
        for p in faces where shows(p) { strong.move(to: core); strong.addLine(to: p) }
        context.stroke(faint, with: .color(color.opacity(0.06 * opacity)), lineWidth: 0.5)
        context.stroke(strong, with: .color(color.opacity(0.22 * opacity)), lineWidth: 0.8)
    }
}
