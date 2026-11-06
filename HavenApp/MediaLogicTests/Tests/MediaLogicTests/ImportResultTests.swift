import XCTest
@testable import MediaLogic

/// haven-go's IMPORT_RESULT line (import_result.go), the only thing that
/// may call an import done.
final class ImportResultTests: XCTestCase {
    func testParsesTheGoLineWithItsLogPrefix() {
        let line = "2026/11/05 02:50:01 📋 IMPORT_RESULT status=complete reason=ok owner=1234 tagged=56 relays=2/3 other_vault=none"
        XCTAssertEqual(ImportResult.parse(line),
                       ImportResult(status: .complete, reasons: ["ok"], owner: 1234, tagged: 56,
                                    relaysReached: 2, relaysTotal: 3, otherVault: "none"))
        XCTAssertTrue(ImportResult.parse(line)!.isComplete)
        XCTAssertEqual(ImportResult.parse(line)!.summary, "Import Complete!")
    }

    func testPartialFailedCancelledAreNeverComplete() {
        let partial = ImportResult.parse("IMPORT_RESULT status=partial reason=walk_deadline,relay_dropped owner=812 tagged=40 relays=3/4 other_vault=none")!
        XCTAssertEqual(partial.reasons, ["walk_deadline", "relay_dropped"])
        XCTAssertFalse(partial.isComplete)
        XCTAssertEqual(partial.summary, "Imported 812 notes, but some may be missing. Run the import again to fill the gaps.")

        let offline = ImportResult.parse("IMPORT_RESULT status=failed reason=no_seed_relay owner=0 tagged=0 relays=0/4 other_vault=none")!
        XCTAssertFalse(offline.isComplete)
        XCTAssertFalse(offline.isRetryableStart)
        XCTAssertEqual(offline.summary, "Couldn't reach any relay. Check your connection, then try again.")

        let cancelled = ImportResult.parse("IMPORT_RESULT status=cancelled reason=cancelled owner=10 tagged=0 relays=4/4 other_vault=none")!
        XCTAssertEqual(cancelled.summary, "Import cancelled")
        for r in [partial, offline, cancelled, ImportResult.noResult, ImportResult.cancelledBeforeStart] {
            XCTAssertNotEqual(r.summary, ImportResult.completeLine)
        }
    }

    func testOnlyALeftoverCycleIsRetried() {
        XCTAssertTrue(ImportResult.parse("IMPORT_RESULT status=failed reason=still_draining owner=0 tagged=0 relays=0/0 other_vault=none")!.isRetryableStart)
        XCTAssertTrue(ImportResult.parse("IMPORT_RESULT status=failed reason=already_running owner=0 tagged=0 relays=0/0 other_vault=none")!.isRetryableStart)
        XCTAssertFalse(ImportResult.parse("IMPORT_RESULT status=failed reason=db_init owner=0 tagged=0 relays=0/0 other_vault=none")!.isRetryableStart)
        XCTAssertFalse(ImportResult.noResult.isRetryableStart)
    }

    func testOtherVaultNotReached() {
        let r = ImportResult.parse("IMPORT_RESULT status=partial reason=other_vault_not_reached owner=300 tagged=2 relays=4/5 other_vault=not_reached")!
        XCTAssertTrue(r.otherVaultNotReached)
        XCTAssertEqual(r.summary, ImportResult.otherVaultNotReachedLine)
        XCTAssertFalse(ImportResult.parse("IMPORT_RESULT status=complete reason=ok owner=1 tagged=0 relays=5/5 other_vault=reached")!.otherVaultNotReached)
    }

    func testUnknownKeysIgnoredAndJunkRefused() {
        XCTAssertEqual(ImportResult.parse("IMPORT_RESULT status=complete reason=ok future=7 owner=3 tagged=1 relays=1/1 other_vault=none")?.owner, 3)
        XCTAssertNil(ImportResult.parse("IMPORT_RESULT status=great reason=ok"))
        XCTAssertNil(ImportResult.parse("✅ Import completed in C-Shared mode"))
        XCTAssertNil(ImportResult.parse(""))
    }

    /// 12 mini 2026-11-05: a refused import left the vault paused with only
    /// "still busy". It says the import didn't run and that the vault is
    /// starting again (endImport restarts it).
    func testARefusedStartSaysTheVaultIsStartingAgain() {
        for reason in ["still_draining", "already_running"] {
            let r = ImportResult.parse("IMPORT_RESULT status=failed reason=\(reason)")
            XCTAssertEqual(r?.isRetryableStart, true, reason)
            XCTAssertEqual(r?.summary, ImportResult.refusedStartLine, reason)
        }
        XCTAssertTrue(ImportResult.refusedStartLine.contains("starting again"))
    }
}
