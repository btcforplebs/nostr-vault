import XCTest
@testable import MediaLogic

/// First-screen sign-in with a bunker (Amber's bunker:// or Clave's
/// nostrconnect) saves the signer only in the shared nip46 fields. On a phone
/// with an owner left over from an earlier install, the signer lookup read
/// that owner's (empty) entry, said "local", and the connect was refused
/// before it reached the signer.
final class SetupBunkerSigningTests: XCTestCase {
    private let leftoverOwner = "npub1leftover"

    /// The 12 mini on 2026-11-18: setup not done, old owner kept, signer
    /// picked on the first screen, no per-account entry.
    private func firstScreenBunker(setupDone: Bool = false) -> HavenConfig {
        var config = HavenConfig()
        config.hasCompletedSetup = setupDone
        config.ownerNpub = leftoverOwner
        config.activeAccountNpub = ""
        config.signingMode = "nip46"
        config.nip46SignerPubkey = "d1306c96"
        config.nip46RelayURL = "wss://relay.powr.build"
        config.nip46BunkerURI = "bunker://d1306c96?relay=wss://relay.powr.build"
        return config
    }

    func testLeftoverOwnerDuringSetupUsesTheSharedBunker() {
        let config = firstScreenBunker()
        XCTAssertTrue(config.accountBunkerConfigs.isEmpty)
        XCTAssertEqual(config.activeSigningMode(), "nip46")
    }

    func testLeftoverLocalPreferenceDuringSetupStillUsesTheSharedBunker() {
        var config = firstScreenBunker()
        config.accountSigningModes[leftoverOwner] = "local"
        XCTAssertEqual(config.activeSigningMode(), "nip46")
    }

    func testNoAccountYetUsesTheSharedBunker() {
        var config = firstScreenBunker()
        config.ownerNpub = ""
        XCTAssertEqual(config.activeSigningMode(), "nip46")
    }

    func testSharedLocalModeDuringSetupStaysLocal() {
        var config = firstScreenBunker()
        config.signingMode = "local"
        XCTAssertEqual(config.activeSigningMode(), "local")
    }

    func testSharedModeWithoutASignerStaysLocal() {
        var config = firstScreenBunker()
        config.nip46SignerPubkey = ""
        config.nip46BunkerURI = ""
        XCTAssertEqual(config.activeSigningMode(), "local")
    }

    /// After setup the per-account entry is the only source, as before.
    func testFinishedSetupReadsOnlyTheAccountEntry() {
        XCTAssertEqual(firstScreenBunker(setupDone: true).activeSigningMode(), "local")
    }

    /// The shared fields belong to the account being set up, not to others.
    func testOtherAccountsDuringSetupAreNotAffected() {
        XCTAssertEqual(firstScreenBunker().signingMode(for: "npub1someoneelse"), "local")
    }
}
