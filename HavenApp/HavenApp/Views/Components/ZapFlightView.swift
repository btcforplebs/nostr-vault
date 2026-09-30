import SwiftUI

#if os(iOS)
import UIKit
#endif

/// A zap's trip across the whole window: the sats leave *your* avatar (the
/// profile tab on iPhone, the account row in the iPad / Mac sidebar), arc
/// over the content, and land on the bolt button of the note being zapped —
/// which then lights up with `ZapBurstView`. Direction matters: the sats are
/// yours going out, so the flight starts at you, not at the author.
///
/// This lives above every screen rather than inside a row because a row is
/// clipped to its own card; anything that has to cross the screen has to be
/// drawn by something that owns the whole window. One `ZapFlightStage` is
/// mounted at each app shell's root, and rows only hand it a target.
@MainActor
final class ZapFlightCoordinator: ObservableObject {
    static let shared = ZapFlightCoordinator()

    struct Flight: Identifiable {
        let id = UUID()
        let launchedAt: Date
        let duration: Double
        let origin: CGRect
        let target: ZapFlightAnchor
        /// Direction and strength of the arc's sideways swing, fixed at
        /// launch so a retargeted flight bends the same way the whole trip.
        let bowSign: CGFloat
        let embers: [Ember]
    }

    /// A spark shed from the head partway along the path, drifting and
    /// cooling on its own after it leaves.
    struct Ember {
        let at: Double        // flight progress (0...1) it breaks off at
        let drift: CGVector   // points per second
        let size: CGFloat
    }

    @Published private(set) var flights: [Flight] = []

    /// Window-space frame of the signed-in account's avatar. Not published:
    /// it moves with the tab bar's collapse animation, and nothing should
    /// re-render for that — it is only read at the moment of launch.
    var originFrame: CGRect = .zero

    /// Starts a flight towards `target` and calls `onArrive` as it lands.
    /// Returns `false` — and does nothing — when there's no flight to show
    /// (Reduce Motion, or no avatar on screen to launch from), so the caller
    /// can fall back to the burst on its own.
    func launch(to target: ZapFlightAnchor, onArrive: @escaping () -> Void) -> Bool {
        guard !Motion.isReduced, originFrame != .zero, target.frame != .zero else { return false }

        let start = CGPoint(x: originFrame.midX, y: originFrame.midY)
        let end = CGPoint(x: target.frame.midX, y: target.frame.midY)
        let distance = hypot(end.x - start.x, end.y - start.y)
        // Long trips get a little more time so the speed reads the same, but
        // never so much that it stops feeling like a single flick.
        let duration = 0.5 + min(Double(distance) / 3600, 0.14)

        let flight = Flight(
            launchedAt: Date(),
            duration: duration,
            origin: originFrame,
            target: target,
            bowSign: end.x >= start.x ? -1 : 1,
            embers: (0..<5).map { i in
                let angle = Double.random(in: 0..<(2 * .pi))
                let speed = Double.random(in: 16...38)
                return Ember(
                    at: 0.14 + Double(i) * 0.12 + Double.random(in: -0.03...0.03),
                    drift: CGVector(dx: cos(angle) * speed, dy: sin(angle) * speed),
                    size: CGFloat.random(in: 1.8...3)
                )
            }
        )
        flights.append(flight)
        Self.impact(.light)

        // Hand off to the burst a beat before the head finishes sinking into
        // the button, so there is no gap between "arriving" and "arrived".
        DispatchQueue.main.asyncAfter(deadline: .now() + duration * ZapFlightPath.arrival) {
            Self.impact(.rigid)
            onArrive()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            self?.flights.removeAll { $0.id == flight.id }
        }
        return true
    }

    #if os(iOS)
    private static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
    #else
    private enum ImpactStyle { case light, rigid }
    private static func impact(_ style: ImpactStyle) {}
    #endif
}

/// A view's window-space frame, kept current on every layout pass (scrolling
/// included) without making anything re-render — it is a plain reference, not
/// state. A flight reads it each frame, so if the feed scrolls mid-flight the
/// bolt still lands on the button instead of where the button used to be.
final class ZapFlightAnchor {
    var frame: CGRect = .zero
}

/// The flight's shape and timing, kept apart from drawing so the numbers can
/// be read in one place.
enum ZapFlightPath {
    /// Progress at which the flight hands off to the target's burst.
    static let arrival: Double = 0.88
    /// How far back in time the trail reaches, as a fraction of the flight.
    /// Measured in time rather than distance so the streak stretches out at
    /// full speed and pulls back into the head as it brakes on landing.
    static let trailLength: Double = 0.14

    /// Picks up speed off the avatar, darts, then settles into the button — a
    /// cubic ease (0.4, 0.05, 0.2, 1) rather than a spring, because something
    /// thrown at a target shouldn't bounce past it.
    static func eased(_ u: Double) -> CGFloat {
        CGFloat(cubicBezierY(atX: min(max(u, 0), 1), 0.4, 0.05, 0.2, 1))
    }

    /// A cubic Bézier from `start` to `end`. It lifts off steeply and swings
    /// out to one side, then curls back in, so it reads as a throw rather
    /// than a slide along a rail.
    static func point(_ t: CGFloat, from start: CGPoint, to end: CGPoint, bowSign: CGFloat) -> CGPoint {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = max(hypot(dx, dy), 1)
        // Unit normal to the straight line between the two ends.
        let nx = -dy / length, ny = dx / length
        let swing = min(length * 0.3, 140) * bowSign
        let p1 = CGPoint(x: start.x + dx * 0.2 + nx * swing, y: start.y + dy * 0.2 + ny * swing)
        let p2 = CGPoint(x: start.x + dx * 0.8 + nx * swing * 0.35, y: start.y + dy * 0.8 + ny * swing * 0.35)
        let mt = 1 - t
        let a = mt * mt * mt, b = 3 * mt * mt * t, c = 3 * mt * t * t, d = t * t * t
        return CGPoint(
            x: a * start.x + b * p1.x + c * p2.x + d * end.x,
            y: a * start.y + b * p1.y + c * p2.y + d * end.y
        )
    }

    /// Solves a CSS-style `cubic-bezier(x1, y1, x2, y2)` timing curve for `x`.
    private static func cubicBezierY(atX x: Double, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> Double {
        func coord(_ s: Double, _ p1: Double, _ p2: Double) -> Double {
            let ms = 1 - s
            return 3 * ms * ms * s * p1 + 3 * ms * s * s * p2 + s * s * s
        }
        var lo = 0.0, hi = 1.0, s = x
        for _ in 0..<20 {
            s = (lo + hi) / 2
            if coord(s, x1, x2) < x { lo = s } else { hi = s }
        }
        return coord(s, y1, y2)
    }
}

/// Draws every flight in progress. Mount once at the root of an app shell,
/// above everything else in it; it never takes a touch.
struct ZapFlightStage: View {
    @ObservedObject private var coordinator = ZapFlightCoordinator.shared

    private static let boltID = 0

    var body: some View {
        GeometryReader { proxy in
            if !coordinator.flights.isEmpty {
                // Anchors are measured in window space; the stage may not sit
                // exactly at the window's origin, so shift into its own space.
                let stageOrigin = proxy.frame(in: .global).origin
                TimelineView(.animation) { timeline in
                    Canvas { context, _ in
                        context.translateBy(x: -stageOrigin.x, y: -stageOrigin.y)
                        context.blendMode = .plusLighter
                        for flight in coordinator.flights {
                            draw(flight, at: timeline.date, in: &context)
                        }
                    } symbols: {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 19, weight: .black))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [.white, Color(red: 1, green: 0.84, blue: 0.45)],
                                    startPoint: .top, endPoint: .bottom
                                )
                            )
                            .tag(Self.boltID)
                    }
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func draw(_ flight: ZapFlightCoordinator.Flight, at date: Date, in context: inout GraphicsContext) {
        let u = min(max(date.timeIntervalSince(flight.launchedAt) / flight.duration, 0), 1)
        let start = CGPoint(x: flight.origin.midX, y: flight.origin.midY)
        let targetFrame = flight.target.frame
        let end = targetFrame == .zero ? start : CGPoint(x: targetFrame.midX, y: targetFrame.midY)
        let t = ZapFlightPath.eased(u)
        let point = { (p: CGFloat) in ZapFlightPath.point(p, from: start, to: end, bowSign: flight.bowSign) }
        let amber = Color(red: 1, green: 0.62, blue: 0.1)

        // Launch: a ring leaves your avatar's edge, like a charge letting go.
        if u < 0.35 {
            let k = u / 0.35
            let radius = flight.origin.width / 2 + 2 + CGFloat(k) * 14
            let ring = Path(ellipseIn: CGRect(x: start.x - radius, y: start.y - radius, width: radius * 2, height: radius * 2))
            context.stroke(ring, with: .color(amber.opacity(0.85 * (1 - k))), lineWidth: 1.5 * (1 - CGFloat(k)) + 0.5)
        }

        // Head fades up fast off the avatar and sinks into the button at the end.
        let headOpacity = u < 0.08 ? u / 0.08 : (u > ZapFlightPath.arrival ? max(0, 1 - (u - ZapFlightPath.arrival) / (1 - ZapFlightPath.arrival)) : 1)

        // Trail: a tapering streak along the path just behind the head,
        // hottest at the head and cooling to nothing at its tail. Built from
        // overlapping strokes that each run all the way to the head — shorter
        // ones wider — so under additive blending the streak thickens and
        // brightens smoothly toward the head, with no seams between pieces.
        let tailStart = ZapFlightPath.eased(u - ZapFlightPath.trailLength)
        context.drawLayer { trail in
            trail.addFilter(.shadow(color: amber.opacity(0.8), radius: 5))
            let layers = 6
            for layer in 0..<layers {
                let f = CGFloat(layer) / CGFloat(layers)
                let from = tailStart + (t - tailStart) * f
                var streak = Path()
                streak.move(to: point(from))
                for i in 1...12 {
                    streak.addLine(to: point(from + (t - from) * CGFloat(i) / 12))
                }
                trail.stroke(
                    streak,
                    with: .color((layer == layers - 1 ? Color.white : amber).opacity(0.36 * headOpacity)),
                    style: StrokeStyle(lineWidth: 1 + 3.8 * f, lineCap: .round, lineJoin: .round)
                )
            }
        }

        // Embers shed along the way, drifting and dimming after they break off.
        for ember in flight.embers where u > ember.at {
            let age = (u - ember.at) * flight.duration
            let life = 0.34
            guard age < life else { continue }
            let origin = point(ZapFlightPath.eased(ember.at))
            let at = CGPoint(x: origin.x + ember.drift.dx * age, y: origin.y + ember.drift.dy * age + 40 * age * age)
            let fade = 1 - age / life
            context.fill(
                Path(ellipseIn: CGRect(x: at.x - ember.size / 2, y: at.y - ember.size / 2, width: ember.size, height: ember.size)),
                with: .color(amber.opacity(0.9 * fade))
            )
        }

        // Head: a white-hot bolt, leaning into the direction it's travelling.
        guard headOpacity > 0, let bolt = context.resolveSymbol(id: Self.boltID) else { return }
        let ahead = point(min(t + 0.02, 1))
        let behind = point(max(t - 0.02, 0))
        let lean = max(-0.35, min(0.35, atan2(ahead.x - behind.x, -(ahead.y - behind.y)) * 0.4))
        let scale = u > ZapFlightPath.arrival ? 1 - 0.4 * CGFloat((u - ZapFlightPath.arrival) / (1 - ZapFlightPath.arrival)) : 1

        var head = context
        head.opacity = headOpacity
        head.translateBy(x: point(t).x, y: point(t).y)
        head.rotate(by: .radians(lean))
        head.scaleBy(x: scale, y: scale)
        head.addFilter(.shadow(color: amber, radius: 8))
        head.addFilter(.shadow(color: .white.opacity(0.6), radius: 2))
        head.draw(bolt, at: .zero)
    }
}

extension View {
    /// Marks this view as the signed-in account's avatar — where a zap's
    /// flight takes off. Put it on the avatar in each app shell's navigation;
    /// when more than one is on screen (the tab bar mid-collapse), the last
    /// to lay out wins, and one leaving the screen only clears its own frame.
    func zapFlightOrigin() -> some View {
        background(GeometryReader { proxy in
            let frame = proxy.frame(in: .global)
            Color.clear
                .onAppear { ZapFlightCoordinator.shared.originFrame = frame }
                .onChange(of: frame) { _, newFrame in ZapFlightCoordinator.shared.originFrame = newFrame }
                .onDisappear {
                    if ZapFlightCoordinator.shared.originFrame == frame {
                        ZapFlightCoordinator.shared.originFrame = .zero
                    }
                }
        })
    }

    /// Keeps `anchor` holding this view's window-space frame, so a flight can
    /// land on it.
    func zapFlightTarget(_ anchor: ZapFlightAnchor) -> some View {
        background(GeometryReader { proxy in
            let frame = proxy.frame(in: .global)
            Color.clear
                .onAppear { anchor.frame = frame }
                .onChange(of: frame) { _, newFrame in anchor.frame = newFrame }
        })
    }
}

#Preview {
    struct Demo: View {
        @State private var anchor = ZapFlightAnchor()
        @State private var burst = false
        var body: some View {
            ZStack {
                Color.black
                VStack {
                    Image(systemName: "bolt")
                        .foregroundStyle(.orange)
                        .frame(width: 32, height: 32)
                        .zapFlightTarget(anchor)
                        .overlay { ZapBurstView(isAnimating: $burst) }
                        .padding(.top, 200)
                        .padding(.leading, 180)
                    Spacer()
                    Circle().fill(.purple).frame(width: 36, height: 36)
                        .zapFlightOrigin()
                        .onTapGesture {
                            _ = ZapFlightCoordinator.shared.launch(to: anchor) { burst = true }
                        }
                        .padding(.bottom, 40)
                }
                ZapFlightStage()
            }
        }
    }
    return Demo()
}
