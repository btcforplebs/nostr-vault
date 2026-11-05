import XCTest
@testable import MediaLogic

/// Setup's second question (Logen 2026-11-05): "New to Nostr Vault?" Yes is
/// the relay import; No copies from the other vault. No backup zip in setup,
/// and no "Who showed you this app?" for people who already use Nostr.
final class NewToVaultQuestionTests: XCTestCase {
    private let q = NewToVaultQuestion.step

    func testAskedRightAfterTheKeyOrRelaySetup() {
        XCTAssertEqual(NewToVaultQuestion.steps(path: .useNostr, isIOS: true), [12, q, 14, 13])
        XCTAssertEqual(NewToVaultQuestion.steps(path: .browse, isIOS: false), [2, q, 4, 8])
        XCTAssertEqual(NewToVaultQuestion.steps(path: .full, isIOS: false), [2, 3, q, 4, 5, 6, 8])
        XCTAssertTrue(NewToVaultQuestion.isAskedAfter(step: 12, path: .useNostr))
        XCTAssertTrue(NewToVaultQuestion.isAskedAfter(step: 2, path: .browse))
        XCTAssertTrue(NewToVaultQuestion.isAskedAfter(step: 3, path: .full))
        XCTAssertFalse(NewToVaultQuestion.isAskedAfter(step: 2, path: .full))
    }

    /// "Who showed you this app?" is only for people new to Nostr.
    func testNoReferrerForPeopleWhoUseNostr() {
        for path in [NewToVaultQuestion.Path.useNostr, .browse, .full] {
            for isIOS in [true, false] {
                XCTAssertFalse(NewToVaultQuestion.steps(path: path, isIOS: isIOS).contains(15), "\(path)")
            }
        }
    }

    func testYesIsTheRelayImport() {
        XCTAssertEqual(NewToVaultQuestion.relayImportStep(path: .useNostr), 14) // relay check → import tour
        XCTAssertEqual(NewToVaultQuestion.relayImportStep(path: .browse), 4)    // Import step
        XCTAssertEqual(NewToVaultQuestion.relayImportStep(path: .full), 4)
    }

    func testBackReturnsToTheStepBefore() {
        XCTAssertEqual(NewToVaultQuestion.previous(path: .useNostr), 12)
        XCTAssertEqual(NewToVaultQuestion.previous(path: .browse), 2)
        XCTAssertEqual(NewToVaultQuestion.previous(path: .full), 3)
    }

    /// Someone else's backup (code 2) is refused with its own message, not
    /// the generic failure, and only 0 counts as restored.
    func testRestoreCodes() {
        XCTAssertNil(BackupRestoreCode.error(code: 0))
        let notOurs = BackupRestoreCode.error(code: 2)
        XCTAssertEqual(notOurs?.contains("isn't this vault's"), true)
        XCTAssertNotEqual(notOurs, BackupRestoreCode.error(code: 1))
        XCTAssertNotNil(BackupRestoreCode.error(code: 1))
    }
}
