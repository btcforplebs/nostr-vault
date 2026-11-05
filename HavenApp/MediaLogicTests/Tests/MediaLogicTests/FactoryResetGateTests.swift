import XCTest
@testable import MediaLogic

final class FactoryResetGateTests: XCTestCase {
    func testIdleVaultResetsAtOnce() {
        XCTAssertEqual(FactoryResetGate.action(importRunning: false, otherJob: false, cancelSent: false, waited: 0), .reset)
    }

    func testRunningImportIsCancelledFirstNotDeletedUnder() {
        XCTAssertEqual(FactoryResetGate.action(importRunning: true, otherJob: false, cancelSent: false, waited: 0), .cancelImport)
    }

    func testCancelledImportIsWaitedOut() {
        XCTAssertEqual(FactoryResetGate.action(importRunning: true, otherJob: false, cancelSent: true, waited: 5), .wait)
        // Once it has let go, the reset goes ahead.
        XCTAssertEqual(FactoryResetGate.action(importRunning: false, otherJob: false, cancelSent: true, waited: 6), .reset)
    }

    func testBackupOrRestoreIsWaitedOutNotCancelled() {
        XCTAssertEqual(FactoryResetGate.action(importRunning: false, otherJob: true, cancelSent: false, waited: 0), .wait)
    }

    func testStillBusyAfterTheLimitDeletesNothing() {
        let limit = FactoryResetGate.waitLimit
        XCTAssertEqual(FactoryResetGate.action(importRunning: true, otherJob: false, cancelSent: true, waited: limit), .refuse)
        XCTAssertEqual(FactoryResetGate.action(importRunning: false, otherJob: true, cancelSent: false, waited: limit), .refuse)
        XCTAssertEqual(FactoryResetGate.action(importRunning: false, otherJob: false, cancelSent: true, waited: limit), .reset)
    }
}
