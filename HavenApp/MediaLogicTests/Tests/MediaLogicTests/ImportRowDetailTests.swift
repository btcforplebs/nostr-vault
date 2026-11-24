import XCTest
@testable import MediaLogic

/// The dashboard's Import notes row keeps the last result after the import
/// ends (parity report gap H, 2026-11-22).
final class ImportRowDetailTests: XCTestCase {
    private let idle = "Since Jan 1, 2023. Last ran now."
    private func result(_ status: ImportResult.Status, _ reasons: [String] = [], owner: Int = 0) -> ImportResult {
        ImportResult(status: status, reasons: reasons, owner: owner, tagged: 0, relaysReached: 0, relaysTotal: 0, otherVault: "none")
    }
    private func detail(importing: Bool = false, outcome: ImportResult? = nil, startFailed: Bool = false) -> String {
        ImportRowDetail.text(isImporting: importing, liveStatus: "Found notes...", outcome: outcome,
                             startFailed: startFailed, couldNotStartLine: "Couldn't start, try again", idle: idle)
    }

    func testRunningShowsTheLiveStatus() {
        XCTAssertEqual(detail(importing: true, outcome: result(.partial, owner: 3)), "Found notes...")
    }

    func testPartialResultStaysAfterTheImportEnds() {
        let line = detail(outcome: result(.partial, ["walk_deadline"], owner: 812))
        XCTAssertTrue(line.contains("some may be missing"), line)
        XCTAssertTrue(line.contains("812"), line)
    }

    func testFailedAndCancelledStayToo() {
        XCTAssertEqual(detail(outcome: result(.failed, ["no_seed_relay"])), "Couldn't reach any relay. Check your connection, then try again.")
        XCTAssertEqual(detail(outcome: result(.cancelled, ["cancelled"])), ImportResult.cancelledLine)
    }

    func testCompleteShowsLastRan() {
        XCTAssertEqual(detail(outcome: result(.complete)), idle)
    }

    func testNoResultYet() {
        XCTAssertEqual(detail(), idle)
        XCTAssertEqual(detail(startFailed: true), "Couldn't start, try again")
    }
}
