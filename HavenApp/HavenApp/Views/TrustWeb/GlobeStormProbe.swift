#if DEBUG
import SwiftUI
import QuartzCore

/// Debug builds only: how wild the network gets and how the globe keeps up.
/// The readout in the corner shows arrivals a minute and lines in flight;
/// every 5 s the frame times go to the log as `GlobeStorm:` lines, for
/// measuring a stress feed (`-GlobeArcsStorm <per second>`).
@MainActor
final class GlobeStormProbe {
    private var stats = GlobeArcs.FrameStats()
    private var lastFrame: TimeInterval?
    private var lastLog: TimeInterval = 0
    private var peakLines = 0

    /// Times one frame's work: `body` ticks and draws it.
    func frame(at date: TimeInterval, lines: () -> Int, _ body: () -> Void) {
        let start = CACurrentMediaTime()
        body()
        let work = CACurrentMediaTime() - start
        let gap = lastFrame.map { date - $0 }
        lastFrame = date
        // A gap after the clock slept isn't a dropped frame.
        stats.record(work: work, gap: gap.flatMap { $0 < 0.5 ? $0 : nil })
        let count = lines()
        peakLines = max(peakLines, count)
        if date - lastLog >= 5, count > 0 {
            lastLog = date
            NSLog("GlobeStorm: %@", "\(count) lines (peak \(peakLines)), \(stats.summary)")
        }
    }
}

/// Arrivals a minute and lines in flight, over the globe's corner.
struct GlobeStormReadout: View {
    let perMinute: Int
    let inFlight: Int

    var body: some View {
        Text("\(perMinute)/min · \(inFlight) flying")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white.opacity(0.7))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.black.opacity(0.4), in: Capsule())
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
#endif
