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

    private func restarts(_ change: (inout HavenConfig) -> Void) -> Bool {
        let before = base()
        var after = before
        change(&after)
        XCTAssertNotEqual(before, after, "the change under test must change the config")
        return RelayConfiguration.launchInputs(config: before, relayDataDir: dir)
            != RelayConfiguration.launchInputs(config: after, relayDataDir: dir)
    }

    func testAppSideSettingsDoNotRestart() {
        XCTAssertFalse(restarts { $0.themeColor = $0.themeColor + "-other" })
        XCTAssertFalse(restarts { $0.textSizeScale = 1.3 })
        XCTAssertFalse(restarts { $0.feedRelays = ["wss://feed.example"] })
        XCTAssertFalse(restarts { $0.activeAccountNpub = "npub1other" })
        // Reaches a running relay live through UpdateBlacklistC.
        XCTAssertFalse(restarts { $0.blacklistedNpubs = ["npub1blocked"] })
    }

    func testRelayFacingSettingsRestart() {
        XCTAssertTrue(restarts { $0.logLevel = "DEBUG" })
        XCTAssertTrue(restarts { $0.relayPort = 4455 })
        XCTAssertTrue(restarts { $0.relayURL = "relay.example.com" })
        XCTAssertTrue(restarts { $0.outboxMaxEventsPerMinute += 10 })
    }

    /// The list files are written beside the relay at start, outside the env
    /// dictionary, so a new env key is covered automatically but these are not.
    func testRelayListFilesRestart() {
        XCTAssertTrue(restarts { $0.dmRelays = ["wss://dm.example"] })
        XCTAssertTrue(restarts { $0.whitelistedNpubs = ["npub1friend"] })
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
