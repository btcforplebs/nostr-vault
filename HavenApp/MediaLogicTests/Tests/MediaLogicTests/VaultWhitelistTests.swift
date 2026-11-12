import XCTest
@testable import MediaLogic

/// The vault whitelist rule (Logen, 2026-11-12 14:19Z, undoing the 11-06
/// key-or-signer rule): the owner, always, even npub-only (OWNER_NPUB), plus
/// every account on this device, watch-only (npub only) included, like Haven.
/// Access is whitelist-wide: the key of any listed npub, AUTHed, reads the
/// whole /private store and list history, not just its own notes. An npub
/// alone reads nothing gated and cannot post as that account.
final class VaultWhitelistTests: XCTestCase {
    private let owner = "npub1fsgzj6t7udv8zhf6zj32mkqhcjcpv52yph5qsdcl0qt94jgdckqs4yjc3w"
    private let keyed = "npub13evkv42fprxqfpqdp966kn2cwpjrk9jflp08yelkkue20g977wpsv6pcap"
    private let signer = "npub1ks0t9yldwmqlr2k8jnm25gs92za45mp5rhwtkk0r0wlz9wg688zs99ny60"
    private let watched = "npub1d3lkmjhu0mml5fy8tny0sqc55ggm9jsevx40pvurwlstvx9a7hpspnlmth"

    private func config() -> HavenConfig {
        var c = HavenConfig()
        c.ownerNpub = owner
        c.whitelistedNpubs = [watched, keyed, signer, " \(keyed) ", owner, ""]
        c.accountCredentials[keyed] = "ncryptsec1placeholder"
        var bunker = AccountBunkerConfig()
        bunker.bunkerURI = "bunker://placeholder"
        c.accountBunkerConfigs[signer] = bunker
        return c
    }

    func testWatchOnlyGetsVaultSpace() {
        XCTAssertEqual(config().vaultWhitelistNpubs, [watched, keyed, signer])
    }

    /// The owner is whitelisted by OWNER_NPUB even with no key here, so the
    /// file need not list it, and it can never be dropped from the vault.
    func testOwnerNpubOnlyStaysThroughTheEnv() throws {
        var c = config()
        c.whitelistedNpubs = [owner]
        XCTAssertEqual(c.vaultWhitelistNpubs, [])
        let rc = try source("Services/RelayConfiguration.swift")
        XCTAssertTrue(rc.contains("\"OWNER_NPUB\""), "the owner reaches the engine through the env")
    }

    /// Taking a key or signer away keeps the account's vault space; only
    /// removing the account itself drops it.
    func testRemovingAKeyKeepsAccessRemovingTheAccountDropsIt() {
        var c = config()
        c.accountCredentials = [:]
        c.accountBunkerConfigs = [:]
        XCTAssertEqual(c.vaultWhitelistNpubs, [watched, keyed, signer])
        c.whitelistedNpubs.removeAll { $0 == watched }
        XCTAssertEqual(c.vaultWhitelistNpubs, [keyed, signer])
    }

    /// Older builds kept the list only in the whitelist file: it joins the
    /// account list at launch (and so keeps its vault space).
    func testLaunchKeepsEveryAccount() {
        XCTAssertEqual(HavenConfig.accountList(saved: [keyed], whitelistFile: [keyed, watched]), [keyed, watched])
        XCTAssertEqual(HavenConfig.accountList(saved: [watched, keyed], whitelistFile: []), [watched, keyed])
    }

    // MARK: Every writer uses the rule (source checks)

    private static let app = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("HavenApp")

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.app.appendingPathComponent(path), encoding: .utf8)
    }

    func testEveryWhitelistWriterUsesTheRule() throws {
        let rc = try source("Services/RelayConfiguration.swift")
        XCTAssertTrue(rc.contains("whitelistedNpubs: config.vaultWhitelistNpubs"), "relay start (launch inputs)")
        for path in ["Services/Relay/RelayProcessManager+Backup.swift", "Services/Relay/RelayProcessManager+Import.swift"] {
            let text = try source(path)
            XCTAssertTrue(text.contains("encoder.encode(config.vaultWhitelistNpubs)"), path)
            XCTAssertFalse(text.contains("encoder.encode(config.whitelistedNpubs)"), path)
        }
        let cs = try source("Services/ConfigService.swift")
        XCTAssertTrue(cs.contains("writeVaultWhitelist(encoder: encoder)"))
        XCTAssertFalse(cs.contains("encoder.encode(config.whitelistedNpubs)"))
        let write = try source("Services/ConfigService+VaultWhitelist.swift")
        XCTAssertTrue(write.contains("let list = config.vaultWhitelistNpubs"))
        XCTAssertTrue(write.contains("relay.applySavedConfig(config)"), "a removed account leaves the running relay too")
        // No other Swift file writes the whitelist file.
        let start = try source("Services/Relay/RelayProcessManager+Start.swift")
        XCTAssertTrue(start.contains("encoder.encode(inputs.whitelistedNpubs)"))
    }
}
