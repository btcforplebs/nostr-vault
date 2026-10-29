import SwiftUI

/// A kind 33331 object (DECK-0003) drawn in a square: a slow turn on its own,
/// and on the thread page a drag turns it by hand.
///
/// Drawn on a `Canvas` from `SnoScene`'s back-to-front list, no 3D engine,
/// the same way the trust globe is drawn. The clock runs at 30 fps at most and
/// stops off screen, in the background, under a finger, in Low Power Mode and
/// with Reduce Motion on; with the clock stopped nothing is redrawn.
struct SnoStageView: View {
    let scene: SnoScene
    /// Drag to turn. Off inside a quote card, where a drag scrolls the feed
    /// and a tap opens the thread.
    var interactive = false

    /// One turn every 24 seconds.
    private static let spinRate = 2 * Double.pi / 24
    private static let restPitch = 0.42

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var appIsActive = true
    @State private var onScreen = false
    /// The angle the clock counts from, and when it started counting.
    @State private var baseYaw = 0.7
    @State private var spinStart = Date()
    @State private var pitch = SnoStageView.restPitch
    @State private var dragStart: (yaw: Double, pitch: Double)?

    private var spins: Bool { onScreen && appIsActive && !reduceMotion && !lowPower && dragStart == nil }

    private func yaw(at date: Date) -> Double {
        guard spins else { return baseYaw }
        return baseYaw + date.timeIntervalSince(spinStart) * Self.spinRate
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !spins)) { timeline in
            let yaw = yaw(at: timeline.date)
            Canvas { context, size in
                draw(in: &context, side: min(size.width, size.height), size: size, yaw: yaw)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .background(
            RadialGradient(colors: [Color(red: 0.12, green: 0.13, blue: 0.19), Color(red: 0.06, green: 0.07, blue: 0.09)],
                           center: UnitPoint(x: 0.5, y: 0.4), startRadius: 0, endRadius: 260)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .gesture(interactive ? turnGesture : nil)
        .onAppear { onScreen = true; restartClock() }
        .onDisappear { freeze(); onScreen = false }
        .onReceive(NotificationCenter.default.publisher(for: AppActivity.didBecomeActive)) { _ in
            appIsActive = true; restartClock()
        }
        .onReceive(NotificationCenter.default.publisher(for: AppActivity.willResignActive)) { _ in
            freeze(); appIsActive = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            DispatchQueue.main.async {
                freeze()
                lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
                restartClock()
            }
        }
        .accessibilityElement()
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isImage)
        .modifier(AdjustableTurn(enabled: interactive) { delta in
            freeze()
            baseYaw += delta
            restartClock()
        })
    }

    private var accessibilityText: String {
        let object = scene.object
        return String(localized: "sno.stage.accessibility",
                      defaultValue: "3D object, \(object.name), \(object.positions.count) vertices")
    }

    /// Keeps the angle where it is when the clock stops, so it resumes from there.
    private func freeze() {
        baseYaw = yaw(at: Date())
        spinStart = Date()
    }

    private func restartClock() { spinStart = Date() }

    private var turnGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if dragStart == nil {
                    freeze()
                    dragStart = (baseYaw, pitch)
                }
                guard let start = dragStart else { return }
                baseYaw = start.yaw + Double(value.translation.width) * 0.012
                pitch = min(max(start.pitch + Double(value.translation.height) * 0.012, -1.45), 1.45)
            }
            .onEnded { _ in
                dragStart = nil
                restartClock()
            }
    }

    private func draw(in context: inout GraphicsContext, side: CGFloat, size: CGSize, yaw: Double) {
        let inset = CGPoint(x: (size.width - side) / 2, y: (size.height - side) / 2)
        func pt(_ p: SIMD2<Double>) -> CGPoint { CGPoint(x: inset.x + p.x, y: inset.y + p.y) }
        let opacity = scene.object.opacity
        let pointRadius: CGFloat = scene.object.mode == .points ? max(side / 110, 2) : max(side / 220, 1)
        let lineWidth: CGFloat = max(side / 230, 1)
        context.opacity = opacity
        for primitive in scene.primitives(yaw: yaw, pitch: pitch, size: Double(side)) {
            switch primitive {
            case .triangle(let a, let b, let c, let rgb):
                var path = Path()
                path.move(to: pt(a)); path.addLine(to: pt(b)); path.addLine(to: pt(c)); path.closeSubpath()
                let color = Self.color(rgb)
                context.fill(path, with: .color(color))
                // A hairline in the same colour closes the antialiasing seam
                // between neighbours. Translucent faces skip it, or every
                // edge would show twice as dark.
                if opacity >= 1 { context.stroke(path, with: .color(color), lineWidth: 0.6) }
            case .line(let a, let b, let ca, let cb):
                var path = Path()
                path.move(to: pt(a)); path.addLine(to: pt(b))
                context.stroke(path, with: .linearGradient(Gradient(colors: [Self.color(ca), Self.color(cb)]),
                                                         startPoint: pt(a), endPoint: pt(b)),
                               style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            case .point(let p, let rgb):
                let c = pt(p)
                context.fill(Path(ellipseIn: CGRect(x: c.x - pointRadius, y: c.y - pointRadius,
                                                    width: pointRadius * 2, height: pointRadius * 2)),
                             with: .color(Self.color(rgb)))
            case .placeholder(let p, let radius):
                let c = pt(p), r = CGFloat(radius)
                context.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                               with: .color(.white.opacity(0.35)),
                               style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
    }

    static func color(_ rgb: SnoObject.RGB) -> Color {
        Color(.sRGB, red: Double(rgb.r) / 255, green: Double(rgb.g) / 255, blue: Double(rgb.b) / 255, opacity: 1)
    }
}

/// VoiceOver: swipe up or down on the stage turns the object 30 degrees.
private struct AdjustableTurn: ViewModifier {
    let enabled: Bool
    let turn: (Double) -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: turn(.pi / 6)
                case .decrement: turn(-.pi / 6)
                @unknown default: break
                }
            }
        } else {
            content
        }
    }
}
