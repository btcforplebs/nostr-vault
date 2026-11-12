import XCTest
@testable import MediaLogic

/// Saving Settings restarts the relay exactly when `LaunchInputs` differ, so
/// this table is the whole safety property of the auto-restart: app-side
/// settings must never bounce the relay, and anything the relay reads at
/// start must.
final class RelayLaunchInputsTests: XCTestCase {
    private let dir = URL(fileURLWithPath: "/tmp/relay-launch-inputs")

    private func base() -> HavenConfig {
        var config = HavenConfig.default
        config.ownerNpub = "npub1owner"
        return config
    }

    private func restarts(from start: HavenConfig? = nil, _ change: (inout HavenConfig) -> Void) -> Bool {
        let before = start ?? base()
        var after = before
        change(&after)
        XCTAssertNotEqual(before, after, "the change under test must change the config")
        return RelayConfiguration.launchInputs(config: before, relayDataDir: dir)
            != RelayConfiguration.launchInputs(config: after, relayDataDir: dir)
    }

    func testAppSideSettingsDoNotRestart() {
        XCTAssertFalse(restarts { $0.themeColor = $0.themeColor + "-other" })
        XCTAssertFalse(restarts { $0.textSizeScale = 1.3 })
        XCTAssertFalse(restarts { $0.activeAccountNpub = "npub1other" })
        // Reaches a running relay live through UpdateBlacklistC.
        XCTAssertFalse(restarts { $0.blacklistedNpubs = ["npub1blocked"] })
    }

    func testRelayFacingSettingsRestart() {
        // The vault reads the owner's read relays now (VaultSeedRelays), so a
        // new read list reaches it on restart.
        XCTAssertTrue(restarts { $0.feedRelays = ["wss://feed.example"] })
        XCTAssertTrue(restarts { $0.logLevel = "DEBUG" })
        XCTAssertTrue(restarts { $0.relayPort = 4455 })
        XCTAssertTrue(restarts { $0.relayURL = "relay.example.com" })
        XCTAssertTrue(restarts { $0.outboxMaxEventsPerMinute += 10 })
    }

    /// The list files are written beside the relay at start, outside the env
    /// dictionary, so a new env key is covered automatically but these are not.
    func testRelayListFilesRestart() {
        XCTAssertTrue(restarts { $0.dmRelays = ["wss://dm.example"] })
        // The whitelist file holds every account (vaultWhitelistNpubs),
        // watch-only included: adding one by npub reaches the relay.
        XCTAssertTrue(restarts { $0.whitelistedNpubs = ["npub1friend"] })
        // A key or signer added to an account already there makes it a
        // private reader (vaultPrivateReaderNpubs): that reaches the relay too.
        var keyed = base()
        keyed.whitelistedNpubs = ["npub1friend"]
        XCTAssertTrue(restarts(from: keyed) { $0.accountCredentials["npub1friend"] = "ncryptsec1placeholder" })
        XCTAssertTrue(restarts { $0.importSeedRelays = ["wss://seed.example"] })
        XCTAssertTrue(restarts { $0.blastrRelays = ["wss://blast.example"] })
    }

    func testUnchangedConfigDoesNotRestart() {
        XCTAssertEqual(
            RelayConfiguration.launchInputs(config: base(), relayDataDir: dir),
            RelayConfiguration.launchInputs(config: base(), relayDataDir: dir)
        )
    }
}
