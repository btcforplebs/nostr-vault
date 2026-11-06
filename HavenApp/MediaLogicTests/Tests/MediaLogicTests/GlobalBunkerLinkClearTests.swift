import XCTest
@testable import MediaLogic

/// Removing an account's signer must not leave its link in the shared
/// nip46* fields: its URI, its secret, or the client key the signer
/// authorized (keychain item `nip46-client-secret`).
final class GlobalBunkerLinkClearTests: XCTestCase {
    private let gone = AccountBunkerConfig(bunkerURI: "bunker://aa?relay=wss://r.example&secret=s1", signerPubkey: String(repeating: "a", count: 64),
                                           relayURL: "wss://r.example", secret: "s1",
                                           clientSecretKey: String(repeating: "1", count: 64), clientPubkey: String(repeating: "c", count: 64))
    private let kept = AccountBunkerConfig(bunkerURI: "bunker://bb?relay=wss://r.example&secret=s2", signerPubkey: String(repeating: "b", count: 64),
                                           relayURL: "wss://r.example", secret: "s2",
                                           clientSecretKey: String(repeating: "2", count: 64), clientPubkey: String(repeating: "d", count: 64))

    private func holding(_ cfg: AccountBunkerConfig) -> HavenConfig {
        var c = HavenConfig()
        c.signingMode = "nip46"
        c.nip46BunkerURI = cfg.bunkerURI
        c.nip46SignerPubkey = cfg.signerPubkey
        c.nip46RelayURL = cfg.relayURL
        c.nip46Secret = cfg.secret
        c.nip46ClientSecretKey = cfg.clientSecretKey
        c.nip46ClientPubkey = cfg.clientPubkey
        return c
    }

    func testTheRemovedAccountsLinkIsClearedEverywhereShared() {
        var c = holding(gone)
        c.accountBunkerConfigs = ["npub1kept": kept]
        XCTAssertTrue(c.clearGlobalBunkerLink(ifHolds: gone))
        XCTAssertEqual(c.signingMode, "local")
        for v in [c.nip46BunkerURI, c.nip46SignerPubkey, c.nip46RelayURL, c.nip46Secret, c.nip46ClientSecretKey, c.nip46ClientPubkey] {
            XCTAssertEqual(v, "")
        }
        // Nothing left for the keychain sync to keep in the shared slot.
        XCTAssertNil(c.nip46ClientSecrets[HavenConfig.nip46ClientSecretAccount])
        XCTAssertEqual(c.nip46ClientSecrets[HavenConfig.nip46ClientSecretAccount(forNpub: "npub1kept")], kept.clientSecretKey)
    }

    func testAnotherAccountsLinkIsLeftAlone() {
        var c = holding(kept)
        XCTAssertFalse(c.clearGlobalBunkerLink(ifHolds: gone))
        XCTAssertEqual(c.nip46ClientSecretKey, kept.clientSecretKey)
        XCTAssertEqual(c.nip46BunkerURI, kept.bunkerURI)
        XCTAssertEqual(c.signingMode, "nip46")
    }

    func testClearingAllAlsoDropsTheClientKey() {
        var c = holding(gone)
        c.clearGlobalBunkerFields()
        XCTAssertEqual(c.nip46ClientSecretKey, "")
        XCTAssertEqual(c.nip46ClientPubkey, "")
        XCTAssertTrue(c.nip46ClientSecrets.isEmpty)
    }

    /// ConfigService can't be built here; both removeBunkerConfig branches
    /// must go through the clearing helpers.
    func testRemoveBunkerConfigUsesTheHelpers() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("HavenApp/Services/ConfigService.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        let start = try XCTUnwrap(src.range(of: "func removeBunkerConfig(forNpub"))
        let body = String(src[start.upperBound...].prefix(1400))
        XCTAssertTrue(body.contains("config.clearGlobalBunkerFields()"))
        XCTAssertTrue(body.contains("config.clearGlobalBunkerLink(ifHolds: old)"))
    }
}
