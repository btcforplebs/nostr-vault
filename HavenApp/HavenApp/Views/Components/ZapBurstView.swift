import SwiftUI

/// The confirmation that a zap went out — anchored to the bolt button
/// itself, not the screen. A signed lightning payment doesn't need a
/// flashbang; it needs one crisp, unmistakable beat that reads as *sent*.
///
/// A single spring-driven `progress` value (0 → 1) drives a soft glow, an
/// expanding ring, and a small scatter of sparks together, so the whole
/// burst reads as one motion instead of a hand-timed sequence of stages.
struct ZapBurstView: View {
    @Binding var isAnimating: Bool

    @State private var progress: CGFloat = 0
    @State private var sparks: [Spark] = Self.makeSparks()

    private struct Spark: Identifiable {
        let id = UUID()
        let angle: Double      // radians
        let distance: CGFloat  // resting travel distance in points
        let size: CGFloat
    }

    private static func makeSparks(count: Int = 6) -> [Spark] {
        (0..<count).map { i in
            let baseAngle = (Double(i) / Double(count)) * 2 * .pi
            return Spark(
                angle: baseAngle + Double.random(in: -0.28...0.28),
                distance: CGFloat.random(in: 16...24),
                size: CGFloat.random(in: 2.5...4)
            )
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.orange.opacity(glowOpacity), Color.orange.opacity(0)],
                        center: .center, startRadius: 0, endRadius: 20
                    )
                )
                .scaleEffect(0.5 + progress * 0.9)

            Circle()
                .stroke(Color.orange.opacity(ringOpacity), lineWidth: 1.25)
                .scaleEffect(0.55 + progress * 1.35)

            ForEach(sparks) { spark in
                Circle()
                    .fill(Color.orange.opacity(sparkOpacity))
                    .frame(width: spark.size, height: spark.size)
                    .offset(
                        x: cos(spark.angle) * spark.distance * progress,
                        y: sin(spark.angle) * spark.distance * progress
                    )
            }
        }
        .frame(width: 44, height: 44)
        .allowsHitTesting(false)
        .onChange(of: isAnimating) { _, newValue in
            if newValue { trigger() }
        }
    }

    /// Fast in, fast out — a beat of light rather than a lingering glow.
    private var glowOpacity: Double {
        progress < 0.2 ? Double(progress / 0.2) * 0.5 : 0.5 * Double(1 - (progress - 0.2) / 0.8)
    }

    private var ringOpacity: Double {
        0.75 * Double(1 - progress)
    }

    private var sparkOpacity: Double {
        Double(1 - progress)
    }

    private func trigger() {
        guard !Motion.isReduced else {
            isAnimating = false
            return
        }
        sparks = Self.makeSparks()
        progress = 0
        withAnimation(Motion.zapBurst) {
            progress = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.46) {
            isAnimating = false
        }
    }
}

#Preview {
    ZStack {
        Color.black
        ZapBurstView(isAnimating: .constant(true))
    }
}
