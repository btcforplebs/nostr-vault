import XCTest
@testable import MediaLogic

/// The composer preview keeps up while you type (Tidy's
/// RESEARCH/NV_COMPOSE_PREVIEW_DELAY_2026_11_27.md): a 150 ms throttle in place
/// of the 250 ms wait that restarted at every key.
final class PreviewThrottleTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000)

    func testWaitIsTheRestOfTheWindow() {
        XCTAssertEqual(PreviewThrottle.window, 0.15)
        XCTAssertEqual(PreviewThrottle.wait(lastDrawAt: t0, now: t0.addingTimeInterval(0.2)), 0)
        XCTAssertEqual(PreviewThrottle.wait(lastDrawAt: t0, now: t0.addingTimeInterval(0.15)), 0)
        XCTAssertEqual(PreviewThrottle.wait(lastDrawAt: t0, now: t0.addingTimeInterval(0.1)), 0.05, accuracy: 1e-6)
        XCTAssertEqual(PreviewThrottle.wait(lastDrawAt: t0, now: t0), 0.15, accuracy: 1e-6)
        XCTAssertEqual(PreviewThrottle.wait(lastDrawAt: .distantPast, now: t0), 0, "never drawn: at once")
    }

    /// What `.task(id: previewKey)` does: every key cancels the pending redraw
    /// and arms a new one `wait` from now. Keys every 120 ms (about 8 keys/s)
    /// for 2.4 s: the old 250 ms debounce redrew only after the last key.
    func testABurstRedrawsWhileTyping() {
        var lastDraw = t0
        var pending: Date?
        var draws: [TimeInterval] = []
        let keys = (1...20).map { t0.addingTimeInterval(Double($0) * 0.12) }
        func fireDue(before now: Date) {
            if let due = pending, due <= now { draws.append(due.timeIntervalSince(t0)); lastDraw = due; pending = nil }
        }
        for key in keys {
            fireDue(before: key)
            pending = key.addingTimeInterval(PreviewThrottle.wait(lastDrawAt: lastDraw, now: key))
        }
        let lastKey = keys.last!
        let duringBurst = draws.count
        fireDue(before: .distantFuture)
        XCTAssertGreaterThanOrEqual(duringBurst, 8, "redrew \(duringBurst) times in 2.4 s of typing")
        XCTAssertLessThanOrEqual(draws.last! - lastKey.timeIntervalSince(t0), PreviewThrottle.window + 1e-6,
                                 "the last key shows within one window")
        for (a, b) in zip(draws, draws.dropFirst()) { XCTAssertGreaterThanOrEqual(b - a, PreviewThrottle.window - 1e-6) }
    }
}
