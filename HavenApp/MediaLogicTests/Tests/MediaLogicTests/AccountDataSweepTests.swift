import XCTest
@testable import MediaLogic

/// Delete Account on one account's page: only that account's files and
/// settings match.
final class AccountDataSweepTests: XCTestCase {
    private let hex = String(repeating: "ab", count: 32)
    private let npub = "npub1" + String(repeating: "x", count: 58)
    private let otherHex = String(repeating: "cd", count: 32)

    func testNamesHoldingTheHexOrNpubMatch() {
        XCTAssertTrue(AccountDataSweep.belongs("\(hex).json", hex: hex, npub: npub))
        XCTAssertTrue(AccountDataSweep.belongs("followersSeenAt.\(hex.uppercased())", hex: hex, npub: npub))
        XCTAssertTrue(AccountDataSweep.belongs("deleted_notes_\(npub).json", hex: hex, npub: npub))
        XCTAssertTrue(AccountDataSweep.belongs("composer_drafts_\(npub.uppercased()).json", hex: hex, npub: npub))
    }

    func testOtherAccountsAndSharedFilesDoNotMatch() {
        XCTAssertFalse(AccountDataSweep.belongs("\(otherHex).json", hex: hex, npub: npub))
        XCTAssertFalse(AccountDataSweep.belongs("deleted_notes_owner.json", hex: hex, npub: npub))
        XCTAssertFalse(AccountDataSweep.belongs("config.json", hex: hex, npub: npub))
        XCTAssertFalse(AccountDataSweep.belongs("profiles_cache.json", hex: hex, npub: npub))
    }

    func testMalformedKeysMatchNothing() {
        XCTAssertFalse(AccountDataSweep.belongs("anything.json", hex: "", npub: ""))
        XCTAssertFalse(AccountDataSweep.belongs("ab.json", hex: "ab", npub: "npub1"))
        XCTAssertFalse(AccountDataSweep.belongs("npub1x.json", hex: "zz", npub: "npub1x"))
        let notHex = String(repeating: "zz", count: 32)
        XCTAssertFalse(AccountDataSweep.belongs("\(notHex).json", hex: notHex, npub: ""))
    }

    func testTheVaultAndConfigAreNeverWalked() {
        XCTAssertTrue(AccountDataSweep.skipped.contains("haven_database"))
        XCTAssertTrue(AccountDataSweep.skipped.contains("config.json"))
    }

    func testSharedListsLoseOnlyThisAccount() throws {
        let list = try XCTUnwrap(AccountDataSweep.scrubbed([otherHex, hex, npub], hex: hex, npub: npub) as? [String])
        XCTAssertEqual(list, [otherHex])
        let dict = try XCTUnwrap(AccountDataSweep.scrubbed([hex: 1, otherHex: 2], hex: hex, npub: npub) as? [String: Int])
        XCTAssertEqual(dict, [otherHex: 2])
    }

    func testUntouchedSettingsAreLeftAlone() {
        XCTAssertNil(AccountDataSweep.scrubbed([otherHex], hex: hex, npub: npub))
        XCTAssertNil(AccountDataSweep.scrubbed([otherHex: 1], hex: hex, npub: npub))
        XCTAssertNil(AccountDataSweep.scrubbed(42, hex: hex, npub: npub))
        XCTAssertNil(AccountDataSweep.scrubbed(hex, hex: hex, npub: npub))
    }
}
