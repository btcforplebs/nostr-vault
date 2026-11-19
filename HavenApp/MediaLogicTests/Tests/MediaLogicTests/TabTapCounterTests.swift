import XCTest
@testable import MediaLogic

/// Tab-bar triple-tap (Logen 2026-11-19): Feed -> Following at the top,
/// Vault -> its main page at the top. The second tap keeps its old job.
final class TabTapCounterTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    func testQuickTapsCountToThree() {
        var c = TabTapCounter()
        XCTAssertEqual(c.register(tab: 0, at: t0), 1)
        XCTAssertEqual(c.register(tab: 0, at: t0 + 0.2), 2)
        XCTAssertEqual(c.register(tab: 0, at: t0 + 0.4), 3)
    }

    func testFourthTapStartsOverInsteadOfFiringAgain() {
        var c = TabTapCounter()
        _ = c.register(tab: 4, at: t0)
        _ = c.register(tab: 4, at: t0 + 0.2)
        XCTAssertEqual(c.register(tab: 4, at: t0 + 0.4), 3)
        XCTAssertEqual(c.register(tab: 4, at: t0 + 0.6), 1)
    }

    func testSlowTapsAreSeparateRuns() {
        var c = TabTapCounter()
        XCTAssertEqual(c.register(tab: 0, at: t0), 1)
        XCTAssertEqual(c.register(tab: 0, at: t0 + TabTapCounter.window + 0.01), 1)
        XCTAssertEqual(c.register(tab: 0, at: t0 + TabTapCounter.window + 0.2), 2)
    }

    func testAnotherTabBreaksTheRun() {
        var c = TabTapCounter()
        _ = c.register(tab: 0, at: t0)
        _ = c.register(tab: 0, at: t0 + 0.1)
        XCTAssertEqual(c.register(tab: 4, at: t0 + 0.2), 1, "Vault after two Feed taps is a first tap")
        XCTAssertEqual(c.register(tab: 0, at: t0 + 0.3), 1)
    }
}
