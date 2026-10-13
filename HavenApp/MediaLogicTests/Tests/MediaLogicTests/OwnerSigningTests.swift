import XCTest
@testable import MediaLogic

/// The local relay's AUTH is signed as the owner whichever account is
/// active, so these checks must read the owner's signer, not the active one.
final class OwnerSigningTests: XCTestCase {
    private let owner = "npub1owner"
    private let other = "npub1other"
    private let bunker = AccountBunkerConfig(bunkerURI: "bunker://x", signerPubkey: "abc")

    /// A bunker set up in the wizard: a bunker config, no accountSigningModes entry.
    private func wizardBunkerOwner(active: String) -> HavenConfig {
        var config = HavenConfig()
        config.ownerNpub = owner
        config.activeAccountNpub = active
        config.accountBunkerConfigs[owner] = bunker
        return config
    }

    func testWizardBunkerOwnerSignsWithBunker() {
        let config = wizardBunkerOwner(active: other)
        XCTAssertNil(config.accountSigningModes[owner])
        XCTAssertTrue(config.ownerSignsWithBunker)
    }

    func testBunkerOwnerCanSignWhileAnotherAccountIsActive() {
        var config = wizardBunkerOwner(active: other)
        config.accountSigningModes[other] = "local"
        XCTAssertTrue(config.ownerCanSign(hasNcryptsecPassword: false))
    }

    func testWatchOnlyOwnerCannotSignWhileABunkerAccountIsActive() {
        var config = HavenConfig()
        config.ownerNpub = owner
        config.activeAccountNpub = other
        config.accountBunkerConfigs[other] = bunker
        config.accountSigningModes[other] = "nip46"
        XCTAssertEqual(config.activeSigningMode(), "nip46")
        XCTAssertFalse(config.ownerSignsWithBunker)
        XCTAssertFalse(config.ownerCanSign(hasNcryptsecPassword: false))
    }

    func testOwnerSetToLocalDoesNotUseItsOldBunker() {
        var config = wizardBunkerOwner(active: owner)
        config.accountSigningModes[owner] = "local"
        XCTAssertFalse(config.ownerSignsWithBunker)
    }

    func testLocalKeysNeedTheirKeyOrPassword() {
        var config = HavenConfig()
        config.ownerNpub = owner
        XCTAssertFalse(config.ownerCanSign(hasNcryptsecPassword: true))
        config.ownerNcryptsec = "ncryptsec1x"
        XCTAssertFalse(config.ownerCanSign(hasNcryptsecPassword: false))
        XCTAssertTrue(config.ownerCanSign(hasNcryptsecPassword: true))
        config.ownerNcryptsec = ""
        config.ownerNsec = String(repeating: "ab", count: 32)
        XCTAssertTrue(config.ownerCanSign(hasNcryptsecPassword: false))
    }
}
