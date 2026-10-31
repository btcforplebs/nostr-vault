import XCTest
@testable import MediaLogic

/// Where a file delete goes (Logen, 2026-10-31): the configured mirrors, the
/// owner's kind 10063 list and the server in the photo's link, once each.
/// "Delete from mirrors" leaves the home vault (Mac relay, FIPS) alone.
/// Only builds the list: no request is sent.
final class BlossomDeleteTargetsTests: XCTestCase {
    private let blob = String(repeating: "ab", count: 32)
    /// Not a key, only an address-shaped string.
    private let meshNpub = "npub1throwawaytestvault"

    private func config(mirrors: [String], mac: String = "", fips: Bool = false) -> HavenConfig {
        var config = HavenConfig()
        config.blossomMirrors = mirrors
        config.macRelayURL = mac
        config.fipsPublishEnabled = fips
        config.fipsAddressSource = "custom"
        config.fipsCustomNpub = meshNpub
        return config
    }

    /// A phone with no mirrors whose vault passed the file on to the 10063
    /// server: that server is now asked, not "No mirrors to delete from".
    func testServerListIsATargetWithNoConfiguredMirrors() {
        let targets = config(mirrors: []).blossomDeleteTargets(
            ownerServerList: ["https://blossom.primal.net"], photoURL: nil, includeHomeVault: false)
        XCTAssertEqual(targets, ["https://blossom.primal.net"])
    }

    func testPhotoLinkServerIsATarget() {
        let photo = URL(string: "https://cdn.example.com/\(blob).jpg")
        let targets = config(mirrors: ["https://blossom.primal.net"]).blossomDeleteTargets(
            ownerServerList: [], photoURL: photo, includeHomeVault: false)
        XCTAssertEqual(targets, ["https://blossom.primal.net", "https://cdn.example.com"])
    }

    func testPhotoLinkKeepsItsPort() {
        let photo = URL(string: "https://media.example.com:8443/\(blob)")
        XCTAssertEqual(config(mirrors: []).blossomDeleteTargets(
            ownerServerList: [], photoURL: photo, includeHomeVault: true), ["https://media.example.com:8443"])
    }

    /// The same server typed three ways is asked once.
    func testOneServerOnce() {
        let photo = URL(string: "https://Blossom.Primal.net/\(blob).png")
        let targets = config(mirrors: ["https://blossom.primal.net/"]).blossomDeleteTargets(
            ownerServerList: ["https://blossom.primal.net", "http://blossom.primal.net"],
            photoURL: photo, includeHomeVault: false)
        XCTAssertEqual(targets, ["https://blossom.primal.net/"])
    }

    /// A local or mesh link is this device's or the vault's own copy, never
    /// an outside server.
    func testLocalAndMeshLinksAreNotOutsideServers() {
        for link in ["http://127.0.0.1:3355/\(blob)", "https://localhost:3355/\(blob)",
                     "http://\(meshNpub).fips:3355/\(blob)", "file:///tmp/\(blob)"] {
            XCTAssertEqual(config(mirrors: []).blossomDeleteTargets(
                ownerServerList: [], photoURL: URL(string: link), includeHomeVault: false), [], link)
        }
    }

    func testMirrorsOnlyLeavesTheHomeVault() {
        let config = config(mirrors: ["https://blossom.primal.net"], mac: "wss://mac.example.com", fips: true)
        let mirrorsOnly = config.blossomDeleteTargets(
            ownerServerList: ["https://mac.example.com/"], photoURL: nil, includeHomeVault: false)
        XCTAssertEqual(mirrorsOnly, ["https://blossom.primal.net"])

        let everywhere = config.blossomDeleteTargets(
            ownerServerList: ["https://mac.example.com/"], photoURL: nil, includeHomeVault: true)
        XCTAssertEqual(everywhere, ["https://mac.example.com", "https://blossom.primal.net",
                                    "http://\(meshNpub).fips:\(config.relayPort)"])
    }

    /// The upload rules apply: nostr.build's website maps to its Blossom
    /// server and the dead nostr.band is skipped.
    func testUploadServerRulesApply() {
        let targets = config(mirrors: []).blossomDeleteTargets(
            ownerServerList: ["https://nostr.band", "https://nostr.build"],
            photoURL: URL(string: "https://image.nostr.build/\(blob).jpg"), includeHomeVault: false)
        XCTAssertEqual(targets, ["https://blossom.nostr.build"])
    }

    // MARK: - Delete from mirrors never reaches an owner's vault (Tron ship check 10-31)

    /// A mesh-only phone (no Mac set) whose 10063 names the owner's vaults by
    /// their home-network and mesh addresses: none of them is a mirror.
    func testMirrorsOnlySkipsEveryHomeNetworkAndMeshEntry() {
        let vaults = ["http://192.168.1.20:3355", "https://studio-mac.local:3355", "http://10.44.194.35:3355",
                      "https://mac.tail1234.ts.net", "http://[fd00::20]:3355",
                      "http://\(meshNpub).fips:3355", "fipsmesh://npub1\(String(repeating: "q", count: 58))/"]
        let config = config(mirrors: ["https://blossom.primal.net"])
        let mirrorsOnly = config.blossomDeleteTargets(
            ownerServerList: vaults, photoURL: URL(string: "http://192.168.1.20:3355/\(blob)"), includeHomeVault: false)
        XCTAssertEqual(mirrorsOnly, ["https://blossom.primal.net"])

        // Delete everywhere is unchanged: it still asks them.
        let everywhere = config.blossomDeleteTargets(ownerServerList: vaults, photoURL: nil, includeHomeVault: true)
        XCTAssertTrue(everywhere.contains("http://192.168.1.20:3355"))
        XCTAssertTrue(everywhere.contains("https://studio-mac.local:3355"))
    }

    /// The configured Mac listed by another phone with its default port
    /// spelled out is still this Mac.
    func testMirrorsOnlySkipsTheMacWrittenWithItsPort() {
        let config = config(mirrors: [], mac: "wss://mac.example.com")
        XCTAssertEqual(config.blossomDeleteTargets(
            ownerServerList: ["https://mac.example.com:443/", "https://blossom.primal.net"],
            photoURL: nil, includeHomeVault: false), ["https://blossom.primal.net"])
    }

    func testHomeNetworkServer() {
        for vault in ["http://192.168.0.5:3355", "https://box.lan", "https://mac.local", "http://127.0.0.1:3355",
                      "http://\(meshNpub).fips:3355", "fipsmesh://whatever/", "not a url"] {
            XCTAssertTrue(HavenConfig.isHomeNetworkServer(vault), vault)
        }
        for mirror in ["https://blossom.primal.net", "https://mac.example.com", "https://8.8.8.8"] {
            XCTAssertFalse(HavenConfig.isHomeNetworkServer(mirror), mirror)
        }
    }

    /// Another phone's Mac under a public name looks like any mirror; its
    /// relay info names the owner, so it is kept.
    func testVaultCheckVerdict() {
        let owner = String(repeating: "c", count: 64)
        func info(_ json: String) -> Data { Data(json.utf8) }
        XCTAssertEqual(HavenConfig.vaultCheckVerdict(
            info: info(#"{"name":"outbox","pubkey":"\#(owner.uppercased())","software":"https://github.com/barrydeen/haven"}"#),
            ownerHex: owner), .ownVault)
        XCTAssertEqual(HavenConfig.vaultCheckVerdict(
            info: info(#"{"name":"relay","pubkey":"\#(String(repeating: "d", count: 64))"}"#), ownerHex: owner), .mirror)
        XCTAssertEqual(HavenConfig.vaultCheckVerdict(info: info("<html>Blossom</html>"), ownerHex: owner), .mirror)
        XCTAssertEqual(HavenConfig.vaultCheckVerdict(info: Data(), ownerHex: owner), .mirror)
        XCTAssertEqual(HavenConfig.vaultCheckVerdict(info: nil, ownerHex: owner), .unknown)
        XCTAssertEqual(HavenConfig.vaultCheckVerdict(info: info(#"{"pubkey":"\#(owner)"}"#), ownerHex: ""), .unknown)
    }
}
