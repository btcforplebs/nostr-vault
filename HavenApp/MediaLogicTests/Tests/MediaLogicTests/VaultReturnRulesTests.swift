import XCTest
@testable import MediaLogic

/// The Vault tab on return and on an account switch (Logen 2026-11-13: red
/// tab, rows injected piece by piece, followers first).
final class VaultReturnRulesTests: XCTestCase {
    // MARK: - One swap per refresh

    func testNotReadingShowsAtOnce() {
        XCTAssertTrue(VaultListSwap.publishes(force: false, refreshing: false, heldFor: nil))
    }

    func testReadingHoldsTheOldList() {
        XCTAssertFalse(VaultListSwap.publishes(force: false, refreshing: true, heldFor: nil))
        XCTAssertFalse(VaultListSwap.publishes(force: false, refreshing: true, heldFor: 1))
    }

    func testAStuckReadStopsHoldingAtTheCap() {
        XCTAssertTrue(VaultListSwap.publishes(force: false, refreshing: true, heldFor: VaultListSwap.cap))
    }

    func testASavedScreenShowsAtOnce() {
        XCTAssertTrue(VaultListSwap.publishes(force: true, refreshing: true, heldFor: nil))
    }

    // MARK: - Saved screen

    func testSnapshotKeepsTheNewest() {
        let kept = VaultSnapshotRules.newest([3, 9, 1, 7], keep: 2) { Int64($0) }
        XCTAssertEqual(kept, [9, 7])
    }

    func testSnapshotFileNameIsOnlyAHexKey() {
        let hex = String(repeating: "Ab", count: 32)
        XCTAssertEqual(VaultSnapshotRules.fileName(account: hex), "vault-\(hex.lowercased()).json")
        XCTAssertNil(VaultSnapshotRules.fileName(account: "../../etc"))
        XCTAssertNil(VaultSnapshotRules.fileName(account: ""))
    }

    // MARK: - One dot per account

    func testEachAccountKeepsItsOwnDot() {
        var ledger = VaultNewsAccounts<String>()
        // A has news; switch to B, never opened here: nothing new, nothing seen.
        var shown = ledger.switchAccount(from: "A", to: "B", modes: ["likes"], dmSeen: 2)
        XCTAssertEqual(shown.modes, [])
        XCTAssertEqual(shown.dmSeen, 0)
        // Back to A: its dot is still there.
        shown = ledger.switchAccount(from: "B", to: "A", modes: [], dmSeen: 0)
        XCTAssertEqual(shown.modes, ["likes"])
        XCTAssertEqual(shown.dmSeen, 2)
    }

    func testKeysIgnoreCase() {
        var ledger = VaultNewsAccounts<String>()
        _ = ledger.switchAccount(from: "AB", to: "cd", modes: ["zaps"], dmSeen: 1)
        XCTAssertEqual(ledger.switchAccount(from: "cd", to: "ab", modes: [], dmSeen: 0).modes, ["zaps"])
    }

    func testOnlyNewerThanTheLastVisitIsNews() {
        XCTAssertFalse(VaultNewsAccounts<String>.isNews(createdAt: [100, 200], lastVisit: 200),
                       "a catch-up of things already seen")
        XCTAssertTrue(VaultNewsAccounts<String>.isNews(createdAt: [100, 201], lastVisit: 200))
        XCTAssertTrue(VaultNewsAccounts<String>.isNews(createdAt: [5], lastVisit: nil), "never visited")
        XCTAssertFalse(VaultNewsAccounts<String>.isNews(createdAt: [], lastVisit: nil))
    }

    // MARK: - Wiring

    private static let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.app.appendingPathComponent(path), encoding: .utf8)
    }

    func testReturnFetchesOnlyWhatIsNew() throws {
        let scene = try source("HavenApp-iOS/SceneDelegate.swift")
        XCTAssertTrue(scene.contains("NostrService.shared.fetchNotes(from: urls, since: since)"))
        XCTAssertFalse(scene.contains("NostrService.shared.fetchNotes(from: urls)\n"))
        XCTAssertTrue(scene.contains("NostrService.shared.saveVaultSnapshot()"))
    }

    func testTheVaultListPublishesThroughTheSwap() throws {
        let data = try source("HavenApp/Views/Vault/VaultDataProcessing.swift")
        let gate = try XCTUnwrap(data.range(of: "self.listSwapPublishes(owner: owner, eventCount: events.count)"))
        let publish = try XCTUnwrap(data.range(of: "self.displayActivity = shown"))
        XCTAssertLessThan(gate.lowerBound, publish.lowerBound)
        for path in ["HavenApp/Views/Vault/VaultView.swift", "HavenApp/Views/Vault/VaultView+Content.swift"] {
            let view = try source(path)
            XCTAssertTrue(view.contains("listSwapAccountSwitched()"), path)
            XCTAssertTrue(view.contains("listSwapReadChanged()"), path)
        }
    }

    func testAccountSwitchSavesThenRestores() throws {
        let conn = try source("HavenApp/Services/Nostr/NostrService+Connection.swift")
        let save = try XCTUnwrap(conn.range(of: "saveVaultSnapshot()"))
        let clear = try XCTUnwrap(conn.range(of: "events.removeAll()", range: save.upperBound..<conn.endIndex))
        let restore = try XCTUnwrap(conn.range(of: "restoreVaultSnapshot()"))
        XCTAssertLessThan(save.lowerBound, clear.lowerBound)
        XCTAssertLessThan(clear.lowerBound, restore.lowerBound)
        XCTAssertTrue(conn.contains("switchNewsDot(from: previous, to: activeHexPubkey)"))
    }

    func testTheDotIsProposedNotLitByTheLogLine() throws {
        let capture = try source("HavenApp/Services/Relay/RelayProcessManager+OutputCapture.swift")
        XCTAssertTrue(capture.contains("proposeNews(landed)"))
        XCTAssertFalse(capture.contains("newActivityModes.formUnion(landed)"))
    }
}
