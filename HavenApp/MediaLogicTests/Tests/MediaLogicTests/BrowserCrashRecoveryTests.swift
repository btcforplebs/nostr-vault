import XCTest
@testable import MediaLogic

/// The .fips / web browser page that went blank (Logen 2026-11-14): WebKit's page process died and nothing reloaded it.
final class BrowserCrashRecoveryTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testFirstDeathReloadsByItself() {
        var r = BrowserCrashRecovery()
        XCTAssertEqual(r.processDied(at: t0), .reload)
    }

    func testDyingAgainRightAfterTheReloadAsksInsteadOfLooping() {
        var r = BrowserCrashRecovery()
        _ = r.processDied(at: t0)
        XCTAssertEqual(r.processDied(at: t0.addingTimeInterval(5)), .askToReload)
        XCTAssertEqual(r.processDied(at: t0.addingTimeInterval(10)), .askToReload, "still no loop")
    }

    func testALaterDeathGetsItsOwnReload() {
        var r = BrowserCrashRecovery()
        _ = r.processDied(at: t0)
        XCTAssertEqual(r.processDied(at: t0.addingTimeInterval(BrowserCrashRecovery.window + 1)), .reload)
    }

    func testTryAgainResetsIt() {
        var r = BrowserCrashRecovery()
        _ = r.processDied(at: t0)
        XCTAssertEqual(r.processDied(at: t0.addingTimeInterval(1)), .askToReload)
        r.readerActed()
        XCTAssertEqual(r.processDied(at: t0.addingTimeInterval(2)), .reload)
    }
}
