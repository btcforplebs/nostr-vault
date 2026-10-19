import XCTest
@testable import MediaLogic

/// The Mac relay field also takes the Mac's mesh npub: the relay then reaches
/// the Mac through FIPS at a local ws:// address, and nothing else treats the
/// npub as a host name.
final class MacMeshRelayTests: XCTestCase {
    // Random strings in the npub charset, not real accounts.
    private let macNpub = "npub1z2g42utgkc5tv49xgwy7lplfd8048vuwv9krcc23m828kdjm3cl68tgcyy"
    private let otherNpub = "npub1h8ts9gragczufl8v44chxgut0a870ranmjws865ejtvphmn0czt7cp5dae"
    private let meshURL = "ws://127.0.0.1:41234/abcdef0123456789"

    private func config(mac: String) -> HavenConfig {
        var config = HavenConfig()
        config.macRelayURL = mac
        return config
    }

    func testMeshNpubIsRecognisedInEachPastedForm() {
        for typed in [macNpub, "  \(macNpub)\n", "nostr:\(macNpub)", "fipsmesh://\(macNpub)/"] {
            XCTAssertEqual(config(mac: typed).macRelayMeshNpub, macNpub, typed)
        }
        XCTAssertNil(config(mac: "wss://mac.example.com").macRelayMeshNpub)
        XCTAssertNil(config(mac: "").macRelayMeshNpub)
    }

    func testMeshNpubBecomesTheDialedLocalAddress() {
        let mesh = RelayConfiguration.MacMeshRelay(npub: macNpub, url: meshURL)
        XCTAssertEqual(RelayConfiguration.macRelayURL(config: config(mac: macNpub), mesh: mesh), meshURL)
        XCTAssertEqual(RelayConfiguration.macRelayURL(config: config(mac: "nostr:\(macNpub)"), mesh: mesh), meshURL)
    }

    /// Not dialed yet, or dialed for a different Mac: no address, never the
    /// npub itself as a host.
    func testUndialedOrOtherMeshNpubGivesNoAddress() {
        XCTAssertEqual(RelayConfiguration.macRelayURL(config: config(mac: macNpub), mesh: nil), "")
        let other = RelayConfiguration.MacMeshRelay(npub: otherNpub, url: meshURL)
        XCTAssertEqual(RelayConfiguration.macRelayURL(config: config(mac: macNpub), mesh: other), "")
    }

    func testPlainURLsWorkAsBefore() {
        let mesh = RelayConfiguration.MacMeshRelay(npub: macNpub, url: meshURL)
        XCTAssertEqual(RelayConfiguration.macRelayURL(config: config(mac: "ws://192.168.1.5:3355"), mesh: mesh), "ws://192.168.1.5:3355")
        XCTAssertEqual(RelayConfiguration.macRelayURL(config: config(mac: "wss://mac.example.com/"), mesh: mesh), "wss://mac.example.com")
        XCTAssertEqual(RelayConfiguration.macRelayURL(config: config(mac: "https://mac.example.com"), mesh: nil), "wss://mac.example.com")
    }

    /// A mesh npub has no public address: it must not turn into
    /// wss://npub1… in feeds, broadcasts, Blossom or the published relay lists.
    func testMeshNpubLeaksIntoNoPublicList() {
        var config = config(mac: macNpub)
        config.feedRelays = ["wss://a.example"]
        config.blastrRelays = ["wss://w.example"]
        config.importSeedRelays = []
        XCTAssertEqual(config.macRelayWssURL, "")
        XCTAssertEqual(config.macRelayHttpsURL, "")
        XCTAssertEqual(config.activeFeedRelays, ["wss://a.example"])
        XCTAssertEqual(config.activeBlastrRelays, ["wss://w.example"])
        XCTAssertEqual(config.activeImportSeedRelays, [])
        XCTAssertFalse(config.ownPublicRelays.contains { $0.contains("npub1") })
    }

    /// The phone's notes reach a mesh Mac, first, as they do a URL Mac.
    func testRelayBroadcastsToTheMeshMac() {
        var config = config(mac: macNpub)
        config.blastrRelays = ["wss://w.example"]
        let mesh = RelayConfiguration.MacMeshRelay(npub: macNpub, url: meshURL)
        XCTAssertEqual(RelayConfiguration.blastrRelays(config: config, mesh: mesh), [meshURL, "wss://w.example"])
        XCTAssertEqual(RelayConfiguration.blastrRelays(config: config, mesh: nil), ["wss://w.example"])
        let other = RelayConfiguration.MacMeshRelay(npub: otherNpub, url: meshURL)
        XCTAssertEqual(RelayConfiguration.blastrRelays(config: config, mesh: other), ["wss://w.example"])
    }

    // MARK: - Keeping FIPS up during the Mac copy

    private func status(_ state: String, beat: Int64, url: String? = nil) -> RelayConfiguration.MacSyncStatus {
        var s = RelayConfiguration.MacSyncStatus()
        s.state = state
        s.updatedAt = beat
        s.macURL = url ?? meshURL
        return s
    }

    func testMeshStaysUpWhileTheMacCopyRuns() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let mesh = RelayConfiguration.MacMeshRelay(npub: macNpub, url: meshURL)
        XCTAssertTrue(RelayConfiguration.macSyncNeedsMesh(mesh: mesh, status: status("running", beat: 999_990), now: now))
        // haven-go trims trailing slashes from the URL it records.
        let slashed = RelayConfiguration.MacMeshRelay(npub: macNpub, url: meshURL + "/")
        XCTAssertTrue(RelayConfiguration.macSyncNeedsMesh(mesh: slashed, status: status("running", beat: 999_990), now: now))
    }

    func testMeshIsReleasedOnceTheCopyEndsOrDied() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let mesh = RelayConfiguration.MacMeshRelay(npub: macNpub, url: meshURL)
        for state in ["done", "incomplete", "failed"] {
            XCTAssertFalse(RelayConfiguration.macSyncNeedsMesh(mesh: mesh, status: status(state, beat: 999_990), now: now), state)
        }
        // A "running" whose heartbeat stopped: the relay died mid-copy.
        XCTAssertFalse(RelayConfiguration.macSyncNeedsMesh(mesh: mesh, status: status("running", beat: 999_000), now: now))
        XCTAssertFalse(RelayConfiguration.macSyncNeedsMesh(mesh: mesh, status: nil, now: now))
    }

    /// A URL Mac, or a copy from an earlier dial, never holds the engine.
    func testOnlyACopyOverThisMeshHoldsTheEngine() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let running = status("running", beat: 999_990)
        XCTAssertFalse(RelayConfiguration.macSyncNeedsMesh(mesh: nil, status: running, now: now))
        let mesh = RelayConfiguration.MacMeshRelay(npub: macNpub, url: meshURL)
        let old = status("running", beat: 999_990, url: "ws://127.0.0.1:40000/oldtoken")
        XCTAssertFalse(RelayConfiguration.macSyncNeedsMesh(mesh: mesh, status: old, now: now))
    }
}
