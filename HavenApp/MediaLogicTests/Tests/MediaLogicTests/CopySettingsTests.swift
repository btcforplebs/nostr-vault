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
