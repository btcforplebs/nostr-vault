import XCTest
@testable import MediaLogic

/// Pairing plan §5a: "Already using Nostr Vault on another device?" right
/// after sign-in, before today's relay setup. No is setup as it was; Yes
/// links and copies; a failure falls back to the relay setup and import.
final class OtherDeviceQuestionTests: XCTestCase {
    private let q = OtherDeviceQuestion.step
    private let b = VaultBackupQuestion.step

    func testAskedRightAfterSigningIn() {
        XCTAssertTrue(OtherDeviceQuestion.isAskedAfter(step: 12, path: .useNostr))
        XCTAssertTrue(OtherDeviceQuestion.isAskedAfter(step: 2, path: .browse))
        XCTAssertTrue(OtherDeviceQuestion.isAskedAfter(step: 2, path: .full))
        XCTAssertFalse(OtherDeviceQuestion.isAskedAfter(step: 3, path: .full))
        XCTAssertFalse(OtherDeviceQuestion.isAskedAfter(step: 9, path: .useNostr))
    }

    func testDotsAddOnlyTheQuestion() {
        XCTAssertEqual(OtherDeviceQuestion.steps(VaultBackupQuestion.steps(path: .useNostr, isIOS: true), path: .useNostr),
                       [12, q, b, 14, 13])
        XCTAssertEqual(OtherDeviceQuestion.steps(VaultBackupQuestion.steps(path: .browse, isIOS: false), path: .browse),
                       [2, q, b, 4, 8])
        XCTAssertEqual(OtherDeviceQuestion.steps(VaultBackupQuestion.steps(path: .full, isIOS: false), path: .full),
                       [2, q, 3, b, 4, 5, 6, 8])
        XCTAssertEqual(OtherDeviceQuestion.dotStep(OtherDeviceQuestion.bringOverStep), q)
        XCTAssertEqual(OtherDeviceQuestion.dotStep(14), 14)
    }

    /// No leaves setup exactly as it was before the question existed.
    func testNoIsTodaysSetup() {
        XCTAssertEqual(OtherDeviceQuestion.afterNo(path: .useNostr), b)
        XCTAssertEqual(OtherDeviceQuestion.afterNo(path: .browse), b)
        XCTAssertEqual(OtherDeviceQuestion.afterNo(path: .full), 3)
    }

    func testCopiedSkipsTheRelayImportLikeARestoredBackup() {
        for path: OtherDeviceQuestion.Path in [.useNostr, .browse, .full] {
            XCTAssertEqual(OtherDeviceQuestion.afterCopied(path: path), VaultBackupQuestion.next(after: .restored, path: path))
        }
        XCTAssertEqual(OtherDeviceQuestion.afterCopied(path: .useNostr), .finish)
    }

    /// A failure goes to the relay setup and import, never to an error screen
    /// and never past the import.
    func testFallbackGoesToTheRelayImport() {
        XCTAssertEqual(OtherDeviceQuestion.afterFallback(path: .useNostr), 14)
        XCTAssertEqual(OtherDeviceQuestion.afterFallback(path: .full), 3)
        XCTAssertEqual(OtherDeviceQuestion.afterFallback(path: .browse), 4)
    }

    func testBackFromTheBackupQuestion() {
        XCTAssertEqual(OtherDeviceQuestion.backFromBackupQuestion(path: .useNostr), q)
        XCTAssertEqual(OtherDeviceQuestion.backFromBackupQuestion(path: .browse), q)
        XCTAssertEqual(OtherDeviceQuestion.backFromBackupQuestion(path: .full), 3)
    }

    func testTimeouts() {
        XCTAssertFalse(OtherDeviceQuestion.linkTimedOut(startedAt: 1000, now: 1179))
        XCTAssertTrue(OtherDeviceQuestion.linkTimedOut(startedAt: 1000, now: 1180))
        XCTAssertFalse(OtherDeviceQuestion.isStalled(lastProgressAt: 1000, now: 1119))
        XCTAssertTrue(OtherDeviceQuestion.isStalled(lastProgressAt: 1000, now: 1120))
    }

    /// §5a: no mesh, FIPS, address or role words on these screens.
    func testNoMeshWords() {
        let texts = [OtherDeviceQuestion.title, OtherDeviceQuestion.yes, OtherDeviceQuestion.yesDetail,
                     OtherDeviceQuestion.no, OtherDeviceQuestion.fallbackLine,
                     OtherDeviceQuestion.copyingLine(""), OtherDeviceQuestion.copyingLine("Logen's iPhone"),
                     MeshPairing.roleConfirmText(role: .mac, name: "Mac", setup: true),
                     MeshPairing.roleConfirmText(role: .phone, name: "", setup: true)]
        for text in texts {
            for word in ["mesh", "fips", "npub", "address", "home vault", "role"] {
                XCTAssertFalse(text.lowercased().contains(word), "\(word) in: \(text)")
            }
        }
        XCTAssertEqual(OtherDeviceQuestion.copyingLine(""), "Copying from your other device…")
        XCTAssertEqual(OtherDeviceQuestion.copyingLine("Logen's iPhone"), "Copying from Logen's iPhone…")
    }
}
