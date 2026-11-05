import XCTest
@testable import MediaLogic

final class QuitGuardTests: XCTestCase {
    func testARestoreOrBackupAsksBeforeQuitting() {
        for job in ["restoring", "backingUp"] {
            guard case .ask = QuitGuard.decision(busyJob: job) else {
                return XCTFail("\(job): quit without asking")
            }
        }
    }

    func testNothingRunningQuitsAtOnce() {
        XCTAssertEqual(QuitGuard.decision(busyJob: nil), .quitNow)
        XCTAssertEqual(QuitGuard.decision(busyJob: "importing"), .quitNow)
    }
}
