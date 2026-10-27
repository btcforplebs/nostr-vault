import XCTest
@testable import MediaLogic

/// 3.0.1 #10: people who already use Nostr are asked "Do you have a Vault
/// backup?" before the relay import. Yes restores it and skips the import;
/// No is the flow as it was.
final class VaultBackupQuestionTests: XCTestCase {
    private let q = VaultBackupQuestion.step

    func testAskedRightAfterTheKeyOrRelaySetup() {
        XCTAssertEqual(VaultBackupQuestion.steps(path: .useNostr, isIOS: true), [12, q, 14, 13])
        XCTAssertEqual(VaultBackupQuestion.steps(path: .browse, isIOS: false), [2, q, 4, 8])
        XCTAssertEqual(VaultBackupQuestion.steps(path: .full, isIOS: false), [2, 3, q, 4, 5, 6, 8])
        XCTAssertTrue(VaultBackupQuestion.isAskedAfter(step: 12, path: .useNostr))
        XCTAssertTrue(VaultBackupQuestion.isAskedAfter(step: 2, path: .browse))
        XCTAssertTrue(VaultBackupQuestion.isAskedAfter(step: 3, path: .full))
        XCTAssertFalse(VaultBackupQuestion.isAskedAfter(step: 2, path: .full))
    }

    /// The question is the only new step: every step after it is the one the
    /// path went to before.
    func testNoKeepsTodaysFlow() {
        XCTAssertEqual(VaultBackupQuestion.next(after: .no, path: .useNostr), .step(14)) // relay check → import tour
        XCTAssertEqual(VaultBackupQuestion.next(after: .no, path: .browse), .step(4))    // Import step
        XCTAssertEqual(VaultBackupQuestion.next(after: .no, path: .full), .step(4))
    }

    /// A restored backup never reaches a relay import step.
    func testRestoredSkipsTheRelayImport() {
        let importSteps: Set<Int> = [4, 13, 14]
        for path in [VaultBackupQuestion.Path.useNostr, .browse, .full] {
            switch VaultBackupQuestion.next(after: .restored, path: path) {
            case .finish: break
            case .step(let s): XCTAssertFalse(importSteps.contains(s), "\(path) restored went to step \(s)")
            }
        }
        XCTAssertEqual(VaultBackupQuestion.next(after: .restored, path: .useNostr), .finish)
        XCTAssertEqual(VaultBackupQuestion.next(after: .restored, path: .browse), .step(8))
        XCTAssertEqual(VaultBackupQuestion.next(after: .restored, path: .full), .step(5))
    }

    func testBackReturnsToTheStepBefore() {
        XCTAssertEqual(VaultBackupQuestion.previous(path: .useNostr), 12)
        XCTAssertEqual(VaultBackupQuestion.previous(path: .browse), 2)
        XCTAssertEqual(VaultBackupQuestion.previous(path: .full), 3)
    }
}
