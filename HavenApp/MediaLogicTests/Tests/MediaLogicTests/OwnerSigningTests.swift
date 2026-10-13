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

    /// After a restart with another account active, the owner's bunker must be
    /// logged in beside the active signer, or /chat AUTH has nothing to sign with.
    func testOwnerBunkerNeedsABackgroundSessionWhileAnotherAccountIsActive() {
        XCTAssertTrue(wizardBunkerOwner(active: other).ownerNeedsBackgroundSession)
        // The owner is the active account: the normal connect logs it in.
        XCTAssertFalse(wizardBunkerOwner(active: "").ownerNeedsBackgroundSession)
        XCTAssertFalse(wizardBunkerOwner(active: owner).ownerNeedsBackgroundSession)
        // An owner with a local key has no bunker to log in.
        var local = HavenConfig()
        local.ownerNpub = owner
        local.activeAccountNpub = other
        local.ownerNsec = String(repeating: "ab", count: 32)
        XCTAssertFalse(local.ownerNeedsBackgroundSession)
    }

    /// The Go core files a bunker session under the link's host, the remote
    /// signer. For Clave-style bunkers that differs from the account's own
    /// signerPubkey, so looking the owner's session up by signerPubkey misses.
    func testOwnerSessionIsKeyedByTheBunkerHost() {
        let remoteSigner = String(repeating: "3", count: 64)
        var config = HavenConfig()
        config.ownerNpub = owner
        config.accountBunkerConfigs[owner] = AccountBunkerConfig(
            bunkerURI: "bunker://\(remoteSigner)?relay=wss://r", signerPubkey: "abc")
        XCTAssertEqual(config.ownerSessionKey, remoteSigner)
        XCTAssertEqual(config.ownerBunkerLink, "bunker://\(remoteSigner)?relay=wss://r")
    }

    func testOwnerBunkerLinkIsBuiltWhenNoLinkWasStored() {
        var config = HavenConfig()
        config.ownerNpub = owner
        config.accountBunkerConfigs[owner] = AccountBunkerConfig(signerPubkey: "abc", relayURL: "wss://r")
        XCTAssertEqual(config.ownerBunkerLink, "bunker://abc?relay=wss://r")
        XCTAssertEqual(config.ownerSessionKey, "abc")
        config.accountBunkerConfigs[owner] = nil
        XCTAssertNil(config.ownerBunkerLink)
        XCTAssertNil(config.ownerSessionKey)
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
