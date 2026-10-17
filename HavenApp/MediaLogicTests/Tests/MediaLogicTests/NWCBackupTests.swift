import XCTest
@testable import MediaLogic

/// The saved-wallet slot must stay readable by Wisp and read Wisp's
/// (barrydeen/wisp `Nip78.kt`, `createNwcBackupEvent` / `decryptNwcBackup`).
final class NWCBackupTests: XCTestCase {
    private let uri = "nostr+walletconnect://b889ff5b1513b641e2a139f661a661364979c5beee91842f8f0ef42ab558e9d4?relay=wss%3A%2F%2Frelay.example&secret=71a8c14c1407c113601079c4302dab36460f0ccd0ad506f1f2dc73b5100e4f3c"

    func testWispSlot() {
        XCTAssertEqual(NWCBackup.kind, 30078)
        XCTAssertEqual(NWCBackup.dTag, "nwc-wallet-backup")
        XCTAssertTrue(NWCBackup.tags.contains(["d", "nwc-wallet-backup"]))
        XCTAssertTrue(NWCBackup.tags.contains(["encryption", "nip44"]))
    }

    /// Wisp's own event, as it publishes it, is recognised as the slot.
    func testReadsWispEvent() {
        let wispTags = [["d", "nwc-wallet-backup"], ["client", "Wisp"], ["encryption", "nip44"]]
        XCTAssertTrue(NWCBackup.isBackup(kind: 30078, tags: wispTags))
        XCTAssertFalse(NWCBackup.isCleared(content: "AgV0ciphertext", tags: wispTags))
    }

    func testOtherAppDataIsNotTheSlot() {
        XCTAssertFalse(NWCBackup.isBackup(kind: 30078, tags: [["d", "spark-wallet-backup:0123456789abcdef"]]))
        XCTAssertFalse(NWCBackup.isBackup(kind: 30078, tags: []))
        XCTAssertFalse(NWCBackup.isBackup(kind: 30001, tags: [["d", "nwc-wallet-backup"]]))
    }

    func testClearedSlot() {
        XCTAssertTrue(NWCBackup.isCleared(content: "", tags: NWCBackup.clearedTags))
        XCTAssertTrue(NWCBackup.isCleared(content: "  \n", tags: [["d", "nwc-wallet-backup"]]))
        XCTAssertTrue(NWCBackup.isCleared(content: "AgV0ciphertext", tags: [["d", "nwc-wallet-backup"], ["deleted", "true"]]))
    }

    /// Same check as Wisp: trimmed, `nostr+walletconnect://` in any case.
    func testWalletStringRule() {
        XCTAssertEqual(NWCBackup.walletString(fromDecrypted: "  \(uri)\n"), uri)
        let upper = uri.replacingOccurrences(of: "nostr+walletconnect", with: "NOSTR+WalletConnect")
        XCTAssertEqual(NWCBackup.walletString(fromDecrypted: upper), upper)
        XCTAssertNil(NWCBackup.walletString(fromDecrypted: "lnbc1..."))
        XCTAssertNil(NWCBackup.walletString(fromDecrypted: "abandon abandon abandon"))
        XCTAssertNil(NWCBackup.walletString(fromDecrypted: ""))
    }

    func testSavesTheTrimmedString() {
        XCTAssertEqual(NWCBackup.plaintext(forSaving: " \(uri) "), uri)
        XCTAssertNil(NWCBackup.plaintext(forSaving: "not a wallet"))
    }

    // MARK: - Status: never claim "not saved" without proof

    private let slot = (content: "AgV0ciphertext", tags: [["d", "nwc-wallet-backup"]], createdAt: Int64(1_792_000_000))

    func testNoAnswerIsUnknownNotEmpty() {
        XCTAssertEqual(NWCBackup.status(slot: nil, confirmedNone: false, read: .notTried), .unknown)
        XCTAssertEqual(NWCBackup.status(slot: nil, confirmedNone: true, read: .notTried), .empty)
    }

    func testClearedSlotIsEmpty() {
        let cleared = (content: "", tags: NWCBackup.clearedTags, createdAt: Int64(1))
        XCTAssertEqual(NWCBackup.status(slot: cleared, confirmedNone: false, read: .notTried), .empty)
    }

    /// A slot that exists but wasn't or couldn't be read still has a wallet
    /// in it, so the screen offers Remove and never shows "off".
    func testUnreadSlotStillHasAWallet() {
        let pending = NWCBackup.status(slot: slot, confirmedNone: false, read: .notTried)
        XCTAssertEqual(pending, .needsSigner(savedAt: 1_792_000_000))
        XCTAssertTrue(pending.hasSlot)
        let failed = NWCBackup.status(slot: slot, confirmedNone: false, read: .failed)
        XCTAssertEqual(failed, .unreadable(savedAt: 1_792_000_000))
        XCTAssertTrue(failed.hasSlot)
        XCTAssertEqual(NWCBackup.status(slot: slot, confirmedNone: false, read: .plaintext("not a wallet")),
                       .unreadable(savedAt: 1_792_000_000))
        XCTAssertFalse(NWCBackup.Status.unknown.hasSlot)
        XCTAssertFalse(NWCBackup.Status.empty.hasSlot)
    }

    func testReadSlotIsSaved() {
        XCTAssertEqual(NWCBackup.status(slot: slot, confirmedNone: false, read: .plaintext(" \(uri)\n")),
                       .saved(uri: uri, savedAt: 1_792_000_000))
    }

    /// The wallet string is a spending secret: it never shows up in a log.
    func testStatusDescriptionHidesTheWallet() {
        let saved = NWCBackup.Status.saved(uri: uri, savedAt: 5)
        XCTAssertFalse(String(describing: saved).contains("walletconnect"))
        XCTAssertFalse(String(reflecting: saved).contains("walletconnect"))
        XCTAssertFalse("\(saved)".contains("secret"))
    }

    func testPlaintextNeverPassesAsCiphertext() {
        XCTAssertFalse(NWCBackup.isCiphertext(uri))
        XCTAssertFalse(NWCBackup.isCiphertext(uri.uppercased()))
        XCTAssertFalse(NWCBackup.isCiphertext("  "))
        XCTAssertTrue(NWCBackup.isCiphertext("AgV0b3BzZWNyZXQ="))
    }
}
