import XCTest
@testable import MediaLogic

/// Setup's "Copy from my other vault", the third answer on the import choice:
/// copied skips the relay import like a restored backup; a failure goes to
/// the relay import as "import from my relays" would.
final class OtherVaultCopyTests: XCTestCase {
    private let paths: [OtherVaultCopy.Path] = [.useNostr, .browse, .full]

    /// The copy is reached from the import choice only: no new dot.
    func testNoNewStepInTheDots() {
        for path in paths {
            for isIOS in [true, false] {
                XCTAssertFalse(VaultBackupQuestion.steps(path: path, isIOS: isIOS).contains(OtherVaultCopy.step))
            }
        }
        XCTAssertEqual(OtherVaultCopy.dotStep(OtherVaultCopy.step), VaultBackupQuestion.step)
        XCTAssertEqual(OtherVaultCopy.dotStep(14), 14)
        XCTAssertEqual(OtherVaultCopy.backStep, VaultBackupQuestion.step)
    }

    func testCopiedSkipsTheRelayImportLikeARestoredBackup() {
        for path in paths {
            XCTAssertEqual(OtherVaultCopy.afterCopied(path: path), VaultBackupQuestion.next(after: .restored, path: path))
        }
        XCTAssertEqual(OtherVaultCopy.afterCopied(path: .useNostr), .finish)
    }

    /// A failure lands where "No, import from my relays" goes.
    func testFallbackIsTheRelayImport() {
        XCTAssertEqual(OtherVaultCopy.afterFallback(path: .useNostr), 14)
        XCTAssertEqual(OtherVaultCopy.afterFallback(path: .full), 4)
        XCTAssertEqual(OtherVaultCopy.afterFallback(path: .browse), 4)
        for path in paths {
            XCTAssertEqual(.step(OtherVaultCopy.afterFallback(path: path)), VaultBackupQuestion.next(after: .no, path: path))
        }
    }

    func testTimeouts() {
        XCTAssertFalse(OtherVaultCopy.linkTimedOut(startedAt: 1000, now: 1179))
        XCTAssertTrue(OtherVaultCopy.linkTimedOut(startedAt: 1000, now: 1180))
        XCTAssertFalse(OtherVaultCopy.isStalled(lastProgressAt: 1000, now: 1119))
        XCTAssertTrue(OtherVaultCopy.isStalled(lastProgressAt: 1000, now: 1120))
    }

    /// Logen's wording, and no other mesh, address or role words on the
    /// copy screens (the small print is the one approved mention).
    func testWords() {
        XCTAssertEqual(OtherVaultCopy.button, "Copy from my other vault")
        XCTAssertEqual(OtherVaultCopy.smallPrint,
                       "Your Mac or another device signed in as you. Scan two codes and it copies over the mesh.")
        let texts = [OtherVaultCopy.button, OtherVaultCopy.fallbackLine,
                     OtherVaultCopy.copyingLine(""), OtherVaultCopy.copyingLine("Logen's iPhone"),
                     MeshPairing.roleConfirmText(role: .mac, name: "Mac", setup: true),
                     MeshPairing.roleConfirmText(role: .phone, name: "", setup: true)]
        for text in texts {
            for word in ["mesh", "fips", "npub", "address", "home vault", "role"] {
                XCTAssertFalse(text.lowercased().contains(word), "\(word) in: \(text)")
            }
        }
        XCTAssertEqual(OtherVaultCopy.copyingLine(""), "Copying from your other device…")
        XCTAssertEqual(OtherVaultCopy.copyingLine("Logen's iPhone"), "Copying from Logen's iPhone…")
    }
}
