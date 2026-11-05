import XCTest
@testable import MediaLogic

/// LogePhone 2026-11-05: an import asked for while the vault booted was
/// dropped, and the tour waited for good.
final class ImportStartGateTests: XCTestCase {
    func testBootingBeforeTheRelayCallIsHeldNotDropped() {
        XCTAssertEqual(ImportStartGate.action(vault: .booting, isRunning: false, isShuttingDown: false), .wait)
        XCTAssertEqual(ImportStartGate.action(vault: .stopping, isRunning: true, isShuttingDown: true), .wait)
        XCTAssertEqual(ImportStartGate.action(vault: .idle, isRunning: false, isShuttingDown: true), .wait)
        XCTAssertEqual(ImportStartGate.action(vault: .idle, isRunning: true, isShuttingDown: false), .wait)
    }

    func testIdleStartsAndAnUpRelayStopsFirst() {
        XCTAssertEqual(ImportStartGate.action(vault: .idle, isRunning: false, isShuttingDown: false), .start)
        XCTAssertEqual(ImportStartGate.action(vault: .running, isRunning: true, isShuttingDown: false), .stopThenStart)
        XCTAssertEqual(ImportStartGate.action(vault: .booting, isRunning: true, isShuttingDown: false), .stopThenStart)
        XCTAssertEqual(ImportStartGate.action(vault: .importing, isRunning: false, isShuttingDown: false), .alreadyImporting)
    }

    func testEngineStartIsTheImportBootOnly() {
        XCTAssertTrue(ImportStartGate.isEngineStart("🚀 HAVEN devel is booting up (C-Shared Import Mode)"))
        XCTAssertFalse(ImportStartGate.isEngineStart("🚀 HAVEN (devel) is booting up (C-Shared Mode) [1/3]"))
    }

    func testRetriesAreBounded() {
        XCTAssertTrue(ImportStartGate.shouldRetry(retries: 0))
        XCTAssertTrue(ImportStartGate.shouldRetry(retries: ImportStartGate.maxRefusedRetries - 1))
        XCTAssertFalse(ImportStartGate.shouldRetry(retries: ImportStartGate.maxRefusedRetries))
    }

    func testCouldNotStartAfterSixtySeconds() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        func shows(_ s: TimeInterval, started: Bool = false, failed: Bool = false, completed: Bool = false) -> Bool {
            ImportStartGate.showsCouldNotStart(requestedAt: t0, now: t0.addingTimeInterval(s),
                                               engineStarted: started, failed: failed, completed: completed)
        }
        XCTAssertFalse(shows(59))
        XCTAssertTrue(shows(60))
        XCTAssertFalse(shows(600, started: true))
        XCTAssertFalse(shows(600, completed: true))
        XCTAssertTrue(shows(1, failed: true))
        XCTAssertFalse(ImportStartGate.showsCouldNotStart(requestedAt: nil, now: t0, engineStarted: false, failed: false, completed: false))
        XCTAssertEqual(ImportStartGate.couldNotStart, "Couldn't start, try again")
    }
}
