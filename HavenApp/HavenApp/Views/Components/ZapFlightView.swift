import SwiftUI

/// The sats' visible trip across a note row: a single glowing bolt glyph
/// lifting off the zapped author's avatar and landing on the bolt button
/// that sent it, on a gentle upward arc rather than a straight line. Lands
/// right as `ZapBurstView` lights up the button it arrives at, so the two
/// read as one continuous gesture instead of two unrelated animations.
struct ZapFlightView: View {
    @Binding var isAnimating: Bool
    let start: CGPoint
    let end: CGPoint
    var onArrive: () -> Void = {}

    @State private var progress: CGFloat = 0

    private static let duration: Double = 0.38

    var body: some View {
        if isAnimating, start != .zero, end != .zero {
            Image(systemName: "bolt.fill")
                .font(.system(size: 11, weight: .bold))
                .modifier(FlightPath(progress: progress, start: start, end: end))
                .allowsHitTesting(false)
                .onAppear { trigger() }
        }
    }

    private func trigger() {
        guard !Motion.isReduced else {
            isAnimating = false
            onArrive()
            return
        }
        progress = 0
        withAnimation(Motion.zapFlight) {
            progress = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.duration) {
            isAnimating = false
            onArrive()
        }
    }

    /// Carries `progress` through SwiftUI's animation system as the view
    /// modifier's own `animatableData`, so position, glow, and scale are all
    /// sampled together at each interpolated point along the arc — not
    /// cross-faded between a start state and an end state.
    private struct FlightPath: Animatable, ViewModifier {
        var progress: CGFloat
        let start: CGPoint
        let end: CGPoint

        var animatableData: CGFloat {
            get { progress }
            set { progress = newValue }
        }

        func body(content: Content) -> some View {
            let t = progress
            // A small, fixed lift rather than one scaled to the trip's length —
            // the row this plays in is clipped to its own rounded-rect card, so
            // the peak has to stay inside that bound no matter how far apart the
            // avatar and the bolt end up being.
            let control = CGPoint(
                x: (start.x + end.x) / 2,
                y: max(2, min(start.y, end.y) - 14)
            )
            let point = quadraticPoint(t: t, p0: start, p1: control, p2: end)

            content
                .foregroundStyle(.orange)
                .shadow(color: .orange.opacity(0.65), radius: 3)
                .opacity(opacity(for: t))
                .scaleEffect(scale(for: t))
                .position(point)
        }

        private func quadraticPoint(t: CGFloat, p0: CGPoint, p1: CGPoint, p2: CGPoint) -> CGPoint {
            let mt = 1 - t
            return CGPoint(
                x: mt * mt * p0.x + 2 * mt * t * p1.x + t * t * p2.x,
                y: mt * mt * p0.y + 2 * mt * t * p1.y + t * t * p2.y
            )
        }

        /// Snaps in over the first tenth of the trip, holds at full strength,
        /// then fades through the last fifth so it doesn't visibly overlap
        /// the burst it's about to trigger on arrival.
        private func opacity(for t: CGFloat) -> Double {
            if t < 0.1 { return Double(t / 0.1) }
            if t > 0.8 { return Double(1 - (t - 0.8) / 0.2) }
            return 1
        }

        /// Shrinks slightly on approach, like it's closing distance rather
        /// than floating past the row at a constant size.
        private func scale(for t: CGFloat) -> CGFloat {
            1.1 - 0.35 * t
        }
    }
}

/// Where a `ZapFlightView` in this row reads its two endpoints from: the
/// note's own avatar, and the bolt button, each measured once in the row's
/// shared `"zapFlight"` coordinate space.
struct ZapAvatarFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

struct ZapBoltFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

extension View {
    /// Tags this view's frame, in the row's `"zapFlight"` coordinate space,
    /// as the flight's launch point.
    func zapFlightOrigin() -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: ZapAvatarFrameKey.self, value: proxy.frame(in: .named("zapFlight")))
        })
    }

    /// Tags this view's frame, in the row's `"zapFlight"` coordinate space,
    /// as the flight's landing point.
    func zapFlightDestination() -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: ZapBoltFrameKey.self, value: proxy.frame(in: .named("zapFlight")))
        })
    }
}

#Preview {
    ZStack {
        Color.black
        ZapFlightView(isAnimating: .constant(true), start: CGPoint(x: 40, y: 30), end: CGPoint(x: 260, y: 340))
    }
}
