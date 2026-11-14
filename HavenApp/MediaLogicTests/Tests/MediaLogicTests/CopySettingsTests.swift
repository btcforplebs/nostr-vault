import XCTest
@testable import MediaLogic

/// The settings that travel with the mesh copy (contract §5). The allowlist
/// and the refuse cases are Tal's fixtures; a key added to either side
/// without the other fails here.
final class CopySettingsTests: XCTestCase {

    func testAllowlistMatchesFixture() throws {
        let fx = try MeshCopyV2Tests.fixture("settings-allowlist")
        let keys = try XCTUnwrap(fx["keys"] as? [String: [String: Any]])
        let fixtureTypes = keys.mapValues { $0["type"] as? String ?? "" }
        XCTAssertEqual(fixtureTypes, CopySettings.allowlist.mapValues(\.rawValue))
    }

    /// Every allowlisted key is exported, and nothing else: a setting added
    /// to the allowlist but not to `keys(_:)` (or the reverse) fails the build.
    func testExportCoversExactlyTheAllowlist() throws {
        let exported = CopySettings.keys(HavenConfig())
        XCTAssertEqual(Set(exported.keys), Set(CopySettings.allowlist.keys))
        let data = try XCTUnwrap(CopySettings.fileData(keys: exported, updatedAt: 1_767_000_000))
        guard case .success = CopySettings.check(data, now: 1_767_000_000) else {
            return XCTFail("this app's own export must pass the refuse check")
        }
    }

    func testRefuseCasesMatchFixture() throws {
        let fx = try MeshCopyV2Tests.fixture("settings-refuse-cases")
        let now = try XCTUnwrap(fx["now"] as? NSNumber).int64Value
        let cases = try XCTUnwrap(fx["cases"] as? [[String: Any]])
        XCTAssertGreaterThan(cases.count, 10)
        for c in cases {
            let name = c["name"] as? String ?? "?"
            let expect = try XCTUnwrap(c["expect"] as? [String: Any], name)
            let data = try JSONSerialization.data(withJSONObject: try XCTUnwrap(c["settings"], name))
            switch CopySettings.check(data, now: now) {
            case .success:
                XCTAssertEqual(expect["ok"] as? Bool, true, name)
            case .failure(let e):
                XCTAssertEqual(expect["ok"] as? Bool, false, name)
                XCTAssertEqual(e.reason.rawValue, expect["reason"] as? String, name)
            }
        }
    }

    /// Applying the file's keys and exporting again gives the same keys, so
    /// applying the engine's winner never makes a newer file of its own.
    func testApplyThenExportDoesNotRewrite() throws {
        let fx = try MeshCopyV2Tests.fixture("settings-refuse-cases")
        let first = try XCTUnwrap((fx["cases"] as? [[String: Any]])?.first)
        let data = try JSONSerialization.data(withJSONObject: try XCTUnwrap(first["settings"]))
        guard case .success(let checked) = CopySettings.check(data, now: Int64.max / 2) else {
            return XCTFail("first fixture case is the clean file")
        }
        let applied = CopySettings.apply(checked.keys, to: HavenConfig())
        XCTAssertFalse(CopySettings.differs(applied, from: checked.keys))
        // A local change after that does need a new file.
        var changed = applied
        changed.zapsOnlyMode.toggle()
        XCTAssertTrue(CopySettings.differs(changed, from: checked.keys))
        XCTAssertTrue(CopySettings.differs(applied, from: nil))
    }

    /// This device's own mesh media server is never sent and survives an apply.
    func testMeshMediaServerStaysLocal() {
        var c = HavenConfig()
        c.blossomMirrors = ["https://blossom.example", "fipsmesh://npub1x/blossom", "http://npub1y.fips/"]
        XCTAssertEqual(CopySettings.keys(c)["media_servers"] as? [String], ["https://blossom.example"])
        let applied = CopySettings.apply(["media_servers": ["https://other.example"]], to: c)
        XCTAssertEqual(applied.blossomMirrors,
                       ["https://other.example", "fipsmesh://npub1x/blossom", "http://npub1y.fips/"])
    }
}

/// The build-failing export test (contract §5): a config full of secrets
/// exports only allowlisted keys and none of the secrets. Positive control:
/// the same scan finds every secret in the raw config, so a scan that sees
/// nothing can't pass by accident.
final class CopySettingsSecretExportTests: XCTestCase {
    private let secrets = [
        "nsec1testsecretownerkeyqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq",
        "ncryptsec1testencryptedkeyqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq",
        "nostr+walletconnect://abc?secret=deadbeefcafe",
        "bunker://signer?secret=topsecretbunker",
        String(repeating: "ab", count: 32),
        "s3-secret-key-value-123",
        "npub1meshdevicethatmuststay",
    ]

    private func secretConfig() -> HavenConfig {
        var c = HavenConfig()
        c.ownerNsec = secrets[0]
        c.ownerNcryptsec = secrets[1]
        c.nwcURI = secrets[2]
        c.nip46BunkerURI = secrets[3]
        c.nip46Secret = secrets[3]
        c.nip46ClientSecretKey = secrets[4]
        c.s3SecretKey = secrets[5]
        c.meshDevices = [MeshDevice(npub: secrets[6], name: "Phone", role: .phone)]
        // Allowlisted lists too, so a secret can't hide behind a setting
        // that should be copied (the mesh server is this device's own).
        c.blossomMirrors = ["https://blossom.example", "fipsmesh://\(secrets[6])/blossom"]
        return c
    }

    private func found(in data: Data) -> [String] {
        let text = String(decoding: data, as: UTF8.self)
        return secrets.filter { text.contains($0) }
    }

    /// Every stored value of the config, as text (the JSON encoding leaves
    /// some secrets out, so it would be a weaker control).
    func testRawConfigHoldsEverySecret() {
        var raw = ""
        dump(secretConfig(), to: &raw)
        XCTAssertEqual(found(in: Data(raw.utf8)), secrets)
    }

    func testExportHoldsOnlyAllowlistedKeysAndNoSecret() throws {
        let keys = CopySettings.keys(secretConfig())
        XCTAssertTrue(Set(keys.keys).isSubset(of: Set(CopySettings.allowlist.keys)))
        let data = try XCTUnwrap(CopySettings.fileData(keys: keys, updatedAt: 1_767_000_000))
        XCTAssertEqual(found(in: data), [])
        guard case .success = CopySettings.check(data, now: 1_767_000_000) else {
            return XCTFail("the export must pass the refuse check")
        }
    }

    // MARK: - Retired "condensed" layout (11/14)

    func testApplyReadsCondensedAsExpanded() {
        let applied = CopySettings.apply(["feed_layouts": ["Music": "condensed", "Global": "threaded"]], to: HavenConfig.default)
        XCTAssertEqual(applied.feedLayoutModes["Music"], "expanded")
        XCTAssertEqual(applied.feedLayoutModes["Global"], "threaded")
    }

    func testExportWritesCondensedAsExpanded() throws {
        var config = HavenConfig.default
        config.feedLayoutModes = ["Music": "condensed"]
        let layouts = try XCTUnwrap(CopySettings.keys(config)["feed_layouts"] as? [String: String])
        XCTAssertEqual(layouts, ["Music": "expanded"])
    }

    func testCondensedFileNeedsRewrite() {
        XCTAssertTrue(CopySettings.holdsRetiredLayout(["feed_layouts": ["Music": "condensed"]]))
        XCTAssertFalse(CopySettings.holdsRetiredLayout(["feed_layouts": ["Music": "expanded"]]))
        XCTAssertFalse(CopySettings.holdsRetiredLayout(["zaps_only": true]))
    }
}

