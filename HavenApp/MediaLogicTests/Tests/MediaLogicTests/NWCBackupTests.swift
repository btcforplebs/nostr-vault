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
}
