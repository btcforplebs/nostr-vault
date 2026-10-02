import SwiftUI
import os

#if os(iOS)
import UIKit
import CoreHaptics
#endif

/// A zap's strike across the whole window: a lightning bolt cracks from
/// *your* avatar (the profile tab on iPhone, the account row in the iPad /
/// Mac sidebar) to the bolt button of the note being zapped — which then
/// lights up with `ZapBurstView`. Direction matters: the sats are yours going
/// out, so the strike starts at you, not at the author.
///
/// It plays like real lightning: a dim, jagged leader feels its way across
/// in steps, then the return stroke slams the whole channel white, strobes a
/// few times and dies, with a haptic crack on the strike.
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
        let origin: CGRect
        let target: ZapFlightAnchor
        /// Several jagged shapes of the same channel; each strobe of the
        /// return stroke shows the next, so the bolt crackles instead of
        /// sitting still.
        let channels: [ZapBolt.Channel]
        let branches: [ZapBolt.Branch]
    }

    @Published private(set) var flights: [Flight] = []

    private static let logger = Logger(subsystem: "com.havenapp.relay", category: "ZapFlight")

    /// Window-space frames of every on-screen copy of the signed-in
    /// account's avatar, keyed per copy so one leaving the screen can never
    /// erase another's. Not published: they move with the tab bar's collapse
    /// animation, and nothing should re-render for that — they are only read
    /// at the moment of launch.
    private var origins: [UUID: CGRect] = [:]
    private var latestOrigin: UUID?

    /// Window-space frame of the stage, for launching from the bottom of the
    /// screen when no avatar has reported where it is.
    var stageFrame: CGRect = .zero

    func setOrigin(_ frame: CGRect, for id: UUID) {
        origins[id] = frame
        latestOrigin = id
    }

    func clearOrigin(_ id: UUID) {
        origins[id] = nil
        if latestOrigin == id { latestOrigin = origins.keys.first }
    }

    private var originFrame: CGRect {
        if let id = latestOrigin, let frame = origins[id], frame != .zero { return frame }
        guard stageFrame != .zero else { return .zero }
        // Where the tab bar's avatar sits, give or take.
        return CGRect(x: stageFrame.midX - 12, y: stageFrame.maxY - 72, width: 24, height: 24)
    }

    /// Starts a strike towards `target` and calls `onArrive` as it lands.
    /// Returns `false` — and does nothing — when there's no strike to show
    /// (Reduce Motion, or nowhere to strike between), so the caller can fall
    /// back to the burst on its own.
    func launch(to target: ZapFlightAnchor, onArrive: @escaping () -> Void) -> Bool {
        let originFrame = originFrame
        guard !Motion.isReduced, originFrame != .zero, target.frame != .zero else {
            let reason = "reduceMotion=\(Motion.isReduced) origin=\(originFrame) target=\(target.frame) stage=\(stageFrame)"
            Self.logger.notice("Zap flight skipped: \(reason, privacy: .public)")
            RelayProcessManager.shared.addLog("Zap flight skipped: " + reason)
            return false
        }
        Self.logger.notice("Zap flight launched: origin=\(originFrame.debugDescription, privacy: .public) target=\(target.frame.debugDescription, privacy: .public)")

        let start = CGPoint(x: originFrame.midX, y: originFrame.midY)
        let end = CGPoint(x: target.frame.midX, y: target.frame.midY)
        let length = hypot(end.x - start.x, end.y - start.y)

        let flight = Flight(
            launchedAt: Date(),
            origin: originFrame,
            target: target,
            channels: (0..<ZapBolt.strobes.count).map { _ in ZapBolt.channel(length: length) },
            branches: ZapBolt.branches(length: length)
        )
        flights.append(flight)
        ZapHaptics.shared.charge()

        DispatchQueue.main.asyncAfter(deadline: .now() + ZapBolt.strikeAt) {
            ZapHaptics.shared.strike()
            onArrive()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + ZapBolt.total) { [weak self] in
            self?.flights.removeAll { $0.id == flight.id }
        }
        return true
    }
}

/// A view's window-space frame, kept current on every layout pass (scrolling
/// included) without making anything re-render — it is a plain reference, not
/// state. A strike reads it each frame, so if the feed scrolls mid-strike the
/// bolt still lands on the button instead of where the button used to be.
final class ZapFlightAnchor {
    var frame: CGRect = .zero
}

/// The bolt's shape and timing, kept apart from drawing so the numbers can be
/// read in one place.
///
/// Shapes are stored in the line's own frame — `along` from 0 at your avatar
/// to 1 at the button, `side` in points off that line — so the bolt still
/// joins the two ends if the feed scrolls mid-strike.
enum ZapBolt {
    struct Point { let along: CGFloat; let side: CGFloat }
    typealias Channel = [Point]

    /// A fork off the main channel: starts at one of its vertices and
    /// crackles off to one side for a short way.
    struct Branch {
        let fromIndex: Int
        let points: [Point]   // relative to the fork point
        let reach: Double     // 0...1, how far down the leader it appears
    }

    /// Seconds the stepped leader takes to feel its way across.
    static let leaderTime: Double = 0.26
    /// The return stroke: when the channel slams white and the zap lands.
    static let strikeAt: Double = 0.30
    /// Brightness of each strobe after the strike, one per `strobeStep`.
    static let strobes: [Double] = [1.0, 0.18, 0.95, 0.12, 0.75, 0.4, 0.2]
    static let strobeStep: Double = 0.045
    /// Seconds the screen keeps glowing after the strike.
    static let glowLife: Double = 0.55
    static var total: Double { strikeAt + max(Double(strobes.count) * strobeStep, glowLife) }

    /// A jagged channel by midpoint displacement: split every segment,
    /// shove the midpoint sideways, and halve the shove each round. Ends are
    /// pinned to the avatar and the button.
    static func channel(length: CGFloat) -> Channel {
        var points = [Point(along: 0, side: 0), Point(along: 1, side: 0)]
        var spread = min(max(length * 0.22, 36), 95)
        for _ in 0..<6 {
            var next: [Point] = [points[0]]
            for i in 1..<points.count {
                let a = points[i - 1], b = points[i]
                let mid = Point(
                    along: (a.along + b.along) / 2 + CGFloat.random(in: -0.012...0.012),
                    side: (a.side + b.side) / 2 + CGFloat.random(in: -spread...spread)
                )
                next.append(mid)
                next.append(b)
            }
            points = next
            spread *= 0.58
        }
        return points
    }

    static func branches(length: CGFloat) -> [Branch] {
        let count = length > 260 ? 3 : 2
        let vertices = 65 // 2^6 + 1, the main channel's vertex count
        return (0..<count).map { _ in
            let from = Int.random(in: 8...(vertices - 16))
            let sign: CGFloat = Bool.random() ? 1 : -1
            let reach = CGFloat.random(in: 0.08...0.16)
            var points: [Point] = [Point(along: 0, side: 0)]
            var side: CGFloat = 0
            for step in 1...6 {
                side += sign * CGFloat.random(in: 6...16)
                points.append(Point(along: reach * CGFloat(step) / 6, side: side + CGFloat.random(in: -5...5)))
            }
            return Branch(fromIndex: from, points: points, reach: Double(from) / Double(vertices - 1))
        }
    }

    /// Maps a stored point onto the screen for the current ends.
    static func place(_ p: Point, from start: CGPoint, to end: CGPoint) -> CGPoint {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = max(hypot(dx, dy), 1)
        let nx = -dy / length, ny = dx / length
        return CGPoint(x: start.x + dx * p.along + nx * p.side,
                       y: start.y + dy * p.along + ny * p.side)
    }
}

/// The feel of the strike. A soft double tick while the charge builds, then
/// a hard crack with a short rumble behind it — CoreHaptics where the device
/// has it, the impact generators otherwise.
@MainActor
final class ZapHaptics {
    static let shared = ZapHaptics()

    #if os(iOS)
    private var engine: CHHapticEngine?

    private init() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        engine = try? CHHapticEngine()
        engine?.isAutoShutdownEnabled = true
        engine?.resetHandler = { [weak self] in try? self?.engine?.start() }
    }

    func charge() {
        play([
            Self.tap(at: 0, intensity: 0.35, sharpness: 0.9),
            Self.tap(at: 0.09, intensity: 0.45, sharpness: 1.0),
            Self.tap(at: 0.18, intensity: 0.55, sharpness: 1.0),
        ]) {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    func strike() {
        play([
            // The crack.
            Self.tap(at: 0, intensity: 1.0, sharpness: 1.0),
            // Thunder rolling behind it, dying away.
            CHHapticEvent(eventType: .hapticContinuous, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.8),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.25),
            ], relativeTime: 0.02, duration: 0.32),
            // Aftershocks in time with the strobes.
            Self.tap(at: ZapBolt.strobeStep * 2, intensity: 0.8, sharpness: 0.9),
            Self.tap(at: ZapBolt.strobeStep * 4, intensity: 0.55, sharpness: 0.8),
        ], decay: true) {
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred(intensity: 1)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 1)
            }
        }
    }

    private static func tap(at time: Double, intensity: Float, sharpness: Float) -> CHHapticEvent {
        CHHapticEvent(eventType: .hapticTransient, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
        ], relativeTime: time)
    }

    private func play(_ events: [CHHapticEvent], decay: Bool = false, fallback: () -> Void) {
        guard let engine else { fallback(); return }
        do {
            var curves: [CHHapticParameterCurve] = []
            if decay {
                curves.append(CHHapticParameterCurve(parameterID: .hapticIntensityControl, controlPoints: [
                    .init(relativeTime: 0, value: 1),
                    .init(relativeTime: 0.34, value: 0),
                ], relativeTime: 0.02))
            }
            let pattern = try CHHapticPattern(events: events, parameterCurves: curves)
            try engine.start()
            try engine.makePlayer(with: pattern).start(atTime: CHHapticTimeImmediate)
        } catch {
            fallback()
        }
    }
    #else
    func charge() {}
    func strike() {}
    #endif
}

/// Draws every strike in progress. Mount once at the root of an app shell,
/// above everything else in it; it never takes a touch.
struct ZapFlightStage: View {
    @ObservedObject private var coordinator = ZapFlightCoordinator.shared

    var body: some View {
        GeometryReader { proxy in
            let stageFrame = proxy.frame(in: .global)
            Color.clear
                .onAppear { coordinator.stageFrame = stageFrame }
                .onChange(of: stageFrame) { _, newFrame in coordinator.stageFrame = newFrame }
            if !coordinator.flights.isEmpty {
                // Anchors are measured in window space; the stage may not sit
                // exactly at the window's origin, so shift into its own space.
                let stageOrigin = proxy.frame(in: .global).origin
                TimelineView(.animation) { timeline in
                    Canvas { context, size in
                        context.translateBy(x: -stageOrigin.x, y: -stageOrigin.y)
                        let stage = CGRect(origin: stageOrigin, size: size)
                        for flight in coordinator.flights {
                            draw(flight, at: timeline.date, on: stage, in: &context)
                        }
                    }
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static let amber = Color(red: 1, green: 0.62, blue: 0.1)
    private static let hot = Color(red: 1, green: 0.93, blue: 0.7)
    private static let violet = Color(red: 0.72, green: 0.6, blue: 1)

    private func draw(_ flight: ZapFlightCoordinator.Flight, at date: Date, on stage: CGRect, in context: inout GraphicsContext) {
        let elapsed = date.timeIntervalSince(flight.launchedAt)
        let start = CGPoint(x: flight.origin.midX, y: flight.origin.midY)
        let targetFrame = flight.target.frame
        let end = targetFrame == .zero ? start : CGPoint(x: targetFrame.midX, y: targetFrame.midY)
        let place = { (p: ZapBolt.Point) in ZapBolt.place(p, from: start, to: end) }

        // Charge: the avatar crackles while the leader sets off.
        if elapsed < ZapBolt.strikeAt {
            let k = elapsed / ZapBolt.strikeAt
            let flicker = Double.random(in: 0.5...1)
            let radius = flight.origin.width / 2 + 3 + CGFloat(k) * 8
            let ring = Path(ellipseIn: CGRect(x: start.x - radius, y: start.y - radius, width: radius * 2, height: radius * 2))
            var glow = context
            glow.blendMode = .plusLighter
            glow.addFilter(.shadow(color: Self.amber, radius: 10))
            glow.stroke(ring, with: .color(Self.hot.opacity(0.8 * flicker)), lineWidth: 2)
        }

        if elapsed < ZapBolt.strikeAt {
            // Stepped leader: dim, thin, advancing in jumps rather than a
            // smooth slide, each step re-jittering what is already there.
            let progress = min(elapsed / ZapBolt.leaderTime, 1)
            let steps = 7.0
            let stepped = (progress * steps).rounded(.down) / steps + 1 / steps * 0.6
            let channel = flight.channels[Int(elapsed / 0.03) % flight.channels.count]
            let shown = channel.filter { Double($0.along) <= stepped }
            guard shown.count > 1 else { return }
            strokeBolt(shown.map(place), width: 1.6, brightness: 0.55 * Double.random(in: 0.6...1), in: &context)
            for branch in flight.branches where branch.reach <= stepped {
                let base = place(channel[min(branch.fromIndex, channel.count - 1)])
                strokeBolt(branchPoints(branch, base: base, start: start, end: end), width: 1, brightness: 0.35, in: &context)
            }
            return
        }

        // Return stroke: the whole channel slams white, then strobes.
        let since = elapsed - ZapBolt.strikeAt
        let strobeIndex = Int(since / ZapBolt.strobeStep)
        if strobeIndex < ZapBolt.strobes.count {
            let brightness = ZapBolt.strobes[strobeIndex]
            let channel = flight.channels[strobeIndex % flight.channels.count].map(place)

            // The flash: the screen goes white for an instant.
            if strobeIndex == 0 {
                context.fill(Path(stage), with: .color(.white.opacity(0.22)))
            }
            strokeBolt(channel, width: 6, brightness: brightness, in: &context)
            for branch in flight.branches {
                let base = channel[min(branch.fromIndex, channel.count - 1)]
                strokeBolt(branchPoints(branch, base: base, start: start, end: end), width: 2, brightness: brightness * 0.7, in: &context)
            }
        }

        // Afterglow: warm light floods out from the button and the screen's
        // edges glow for a beat, then it all falls away.
        let landed = since / ZapBolt.glowLife
        if landed < 1 {
            let g = CGFloat(landed)
            let strength = g < 0.1 ? g / 0.1 : 1 - (g - 0.1) / 0.9
            var glow = context
            glow.blendMode = .plusLighter
            glow.fill(
                Path(stage),
                with: .radialGradient(
                    Gradient(colors: [Self.amber.opacity(0.5 * strength), Self.amber.opacity(0.14 * strength), .clear]),
                    center: end, startRadius: 0, endRadius: 120 + 520 * g
                )
            )
            glow.drawLayer { edge in
                edge.addFilter(.blur(radius: 22))
                edge.stroke(Path(stage), with: .color(Self.amber.opacity(0.6 * strength)), lineWidth: 36)
            }
        }
    }

    private func branchPoints(_ branch: ZapBolt.Branch, base: CGPoint, start: CGPoint, end: CGPoint) -> [CGPoint] {
        let origin = ZapBolt.place(ZapBolt.Point(along: 0, side: 0), from: start, to: end)
        return branch.points.map { p in
            let at = ZapBolt.place(p, from: start, to: end)
            return CGPoint(x: base.x + at.x - origin.x, y: base.y + at.y - origin.y)
        }
    }

    /// A bolt as three passes under additive blending: a wide violet-amber
    /// halo, a hot yellow body and a thin white core.
    private func strokeBolt(_ points: [CGPoint], width: CGFloat, brightness: Double, in context: inout GraphicsContext) {
        guard points.count > 1, brightness > 0.01 else { return }
        var path = Path()
        path.move(to: points[0])
        for p in points.dropFirst() { path.addLine(to: p) }

        var layer = context
        layer.blendMode = .plusLighter
        layer.drawLayer { halo in
            halo.addFilter(.blur(radius: width * 3))
            halo.stroke(path, with: .color(Self.violet.opacity(0.5 * brightness)), style: StrokeStyle(lineWidth: width * 5, lineCap: .round, lineJoin: .miter))
            halo.stroke(path, with: .color(Self.amber.opacity(0.7 * brightness)), style: StrokeStyle(lineWidth: width * 3, lineCap: .round, lineJoin: .miter))
        }
        layer.stroke(path, with: .color(Self.hot.opacity(0.9 * brightness)), style: StrokeStyle(lineWidth: width * 1.6, lineCap: .round, lineJoin: .miter))
        layer.stroke(path, with: .color(.white.opacity(brightness)), style: StrokeStyle(lineWidth: max(width * 0.6, 1), lineCap: .round, lineJoin: .miter))
    }
}

extension View {
    /// Marks this view as the signed-in account's avatar — where a zap's
    /// strike takes off. Put it on the avatar in each app shell's navigation;
    /// when more than one is on screen (the tab bar mid-collapse), the last
    /// to lay out wins, and one leaving the screen only clears its own frame.
    func zapFlightOrigin() -> some View {
        modifier(ZapFlightOriginModifier())
    }

    /// Keeps `anchor` holding this view's window-space frame, so a strike can
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

private struct ZapFlightOriginModifier: ViewModifier {
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content.background(GeometryReader { proxy in
            let frame = proxy.frame(in: .global)
            Color.clear
                .onAppear { ZapFlightCoordinator.shared.setOrigin(frame, for: id) }
                .onChange(of: frame) { _, newFrame in ZapFlightCoordinator.shared.setOrigin(newFrame, for: id) }
                .onDisappear { ZapFlightCoordinator.shared.clearOrigin(id) }
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
