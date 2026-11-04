import XCTest
@testable import MediaLogic

/// Reveal Private Key also offers the key locked with the password (NIP-49; NDK check step 4).
final class LockedKeyExportTests: XCTestCase {
    func testKeptCopyIsHandedOverAsItIs() {
        XCTAssertEqual(LockedKeyExport.kept("  ncryptsec1qgg9947rlpvqu76pj5ecreduf9jxhselq2nae2kghhvd5g7dgjtcxfqtd67p9m0w57lspw8gsq6yphnm8623nsl8xn9j4jdzz84zm3frztj3z7s35vpzmqf6ksu8r89qk5z2zxfmu5gv8th8wclt0h4p\n"),
                       "ncryptsec1qgg9947rlpvqu76pj5ecreduf9jxhselq2nae2kghhvd5g7dgjtcxfqtd67p9m0w57lspw8gsq6yphnm8623nsl8xn9j4jdzz84zm3frztj3z7s35vpzmqf6ksu8r89qk5z2zxfmu5gv8th8wclt0h4p")
    }

    /// No kept copy (an older plaintext key, or nothing): the sheet locks a new one with the typed password.
    func testNothingKeptMeansLockANewOne() {
        XCTAssertNil(LockedKeyExport.kept(nil))
        XCTAssertNil(LockedKeyExport.kept(""))
        XCTAssertNil(LockedKeyExport.kept("nsec1abc"))
    }
}

/// Tron, PR 1658: a plaintext owner key reveals for any password, so the copy is locked only with a new password the
/// user types twice (8 or more), never the reveal field.
final class LockedKeyNewPasswordTests: XCTestCase {
    func testNewPasswordRules() {
        XCTAssertEqual(LockedKeyExport.passwordProblem("x", "x"), "Password must be at least 8 characters")
        XCTAssertEqual(LockedKeyExport.passwordProblem("longenough", "longenougx"), "Passwords do not match")
        XCTAssertEqual(LockedKeyExport.passwordProblem("longenough", "longenough"), "")
    }
}
