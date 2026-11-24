import XCTest
@testable import MediaLogic

/// The Desktop Vault list in the settings copy (Desktop Vaults P10, plan §2.6,
/// contract §5): merged per Vault id with tombstones, and never a pairing.
final class CopyVaultsTests: XCTestCase {
    private let now: Int64 = 1_767_000_300

    /// The engine's copyVaultsMerge cases, the same here.
    func testMergeMatchesFixture() throws {
        let fx = try MeshCopyV2Tests.fixture("settings-vault-merge-cases")
        XCTAssertEqual((fx["tombstone_days"] as? NSNumber)?.int64Value, CopySettings.vaultTombDays)
        let at = try XCTUnwrap(fx["now"] as? NSNumber).int64Value
        let cases = try XCTUnwrap(fx["cases"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(cases.count, 10)
        for c in cases {
            let name = c["name"] as? String ?? "?"
            let got = CopySettings.mergeVaults(CopySettings.vaultEntries(c["mine"] as? [Any]),
                                               CopySettings.vaultEntries(c["theirs"] as? [Any]), now: at)
            XCTAssertEqual(got as NSArray, (c["expect"] as? NSArray) ?? [], name)
        }
    }

    /// Two real npubs from the fixtures (a Mac and a box).
    private func npubs() throws -> (mac: String, box: String) {
        let cases = try XCTUnwrap(MeshCopyV2Tests.fixture("settings-refuse-cases")["cases"] as? [[String: Any]])
        let clean = try XCTUnwrap(cases.first { $0["name"] as? String == "vault list, clean" })
        let list = try XCTUnwrap(((clean["settings"] as? [String: Any])?["keys"] as? [String: Any])?["desktop_vaults"] as? [[String: Any]])
        return (try XCTUnwrap(list[0]["meshNpub"] as? String), try XCTUnwrap(list[1]["meshNpub"] as? String))
    }

    private func entry(_ id: String, mesh: String? = nil, https: String? = nil, order: Int = 0,
                       at: Int64 = 1_767_000_000, name: String = "") -> [String: Any] {
        var e: [String: Any] = ["id": id, "name": name, "kind": "mac", "order": order, "updatedAt": at]
        if let mesh { e["meshNpub"] = mesh }
        if let https { e["httpsURL"] = https }
        return e
    }

    private func ids(_ list: [Any]) -> [String] { CopySettings.vaultEntries(list).compactMap { $0["id"] as? String } }

    /// A Vault added on another device comes in; one deleted there goes;
    /// and exporting right after applying dates nothing new.
    func testApplyAddsAndRemovesPerVault() throws {
        var c = HavenConfig()
        c.desktopVaults = [DesktopVault(id: "https:here.example", name: "Here", httpsURL: "https://here.example", order: 0),
                           DesktopVault(id: "https:gone.example", name: "Gone", httpsURL: "https://gone.example", order: 1)]
        let file: [Any] = [entry("https:here.example", https: "https://here.example", order: 0, name: "Here"),
                           entry("https:there.example", https: "https://there.example", order: 1, name: "There"),
                           ["id": "https:gone.example", "deletedAt": 1_767_000_100]]
        let applied = CopySettings.apply(["desktop_vaults": file], to: c, ownNpub: nil)
        XCTAssertEqual(applied.desktopVaults.map(\.id), ["https:here.example", "https:there.example"])
        XCTAssertFalse(CopySettings.differs(applied, from: ["desktop_vaults": file], ownNpub: nil, now: now))
        // Exported against the file it came from, every stamp is the file's.
        let out = try XCTUnwrap(CopySettings.keys(applied, previousVaults: file, ownNpub: nil, now: now)["desktop_vaults"] as? [Any])
        XCTAssertEqual(out as NSArray, CopySettings.mergeVaults(CopySettings.vaultEntries(file), [], now: now) as NSArray)
    }

    /// A Vault deleted here is a tombstone dated now; an edit is dated now;
    /// an unchanged Vault keeps its stamp.
    func testExportDatesWhatChangedHere() throws {
        let previous: [Any] = [entry("https:a.example", https: "https://a.example", order: 0, name: "A"),
                               entry("https:b.example", https: "https://b.example", order: 1, name: "B"),
                               entry("https:c.example", https: "https://c.example", order: 2, name: "C")]
        var c = HavenConfig()
        c.desktopVaults = [DesktopVault(id: "https:a.example", name: "A", httpsURL: "https://a.example", order: 0),
                           DesktopVault(id: "https:b.example", name: "B renamed", httpsURL: "https://b.example", order: 1)]
        let out = CopySettings.vaultEntries(CopySettings.keys(c, previousVaults: previous, ownNpub: nil, now: now)["desktop_vaults"] as? [Any])
        let byID = Dictionary(uniqueKeysWithValues: out.map { ($0["id"] as! String, $0) })
        XCTAssertEqual((byID["https:a.example"]?["updatedAt"] as? NSNumber)?.int64Value, 1_767_000_000)
        XCTAssertEqual((byID["https:b.example"]?["updatedAt"] as? NSNumber)?.int64Value, now)
        XCTAssertEqual((byID["https:c.example"]?["deletedAt"] as? NSNumber)?.int64Value, now)
        XCTAssertNil(byID["https:c.example"]?["httpsURL"])
        // The whole export passes the same refuse check as the engine's.
        let data = try XCTUnwrap(CopySettings.fileData(keys: CopySettings.keys(c, previousVaults: previous, ownNpub: nil, now: now), updatedAt: now))
        guard case .success = CopySettings.check(data, now: now) else { return XCTFail("own export refused") }
    }

    /// A copied Vault grants nothing (§2.6): applying a Vault list that names
    /// a mesh npub this device isn't paired with leaves My Devices as it was,
    /// gives that npub no mesh lane, and the next export doesn't strip or
    /// delete the address it couldn't hold.
    func testCopiedVaultNeverGrantsPairing() throws {
        let (mac, box) = try npubs()
        var c = HavenConfig()
        c.meshDevices = [MeshDevice(npub: mac, name: "Studio Mac", role: .mac)]
        let devicesBefore = c.meshDevices
        let file: [Any] = [entry("mesh:" + mac, mesh: mac, order: 0, name: "Studio Mac"),
                           entry("mesh:" + box, mesh: box, order: 1, name: "Box"),
                           entry("https:web.example", mesh: box, https: "https://web.example", order: 2, name: "Web")]
        let applied = CopySettings.apply(["desktop_vaults": file], to: c, ownNpub: nil)
        XCTAssertEqual(applied.meshDevices, devicesBefore, "a copied Vault changed My Devices")
        let lanes = applied.desktopVaultMeshNpubs(ownNpub: nil)
        XCTAssertTrue(lanes.contains(mac), "positive control: the paired Mac's Vault is dialed")
        XCTAssertFalse(lanes.contains(box), "a copied Vault's unpaired mesh npub got a mesh lane")
        // The address this device can't hold is carried, never deleted or stripped.
        let out = CopySettings.vaultEntries(CopySettings.keys(applied, previousVaults: file, ownNpub: nil, now: now)["desktop_vaults"] as? [Any])
        let byID = Dictionary(uniqueKeysWithValues: out.map { ($0["id"] as! String, $0) })
        XCTAssertEqual(byID["mesh:" + box]?["meshNpub"] as? String, box)
        XCTAssertNil(byID["mesh:" + box]?["deletedAt"])
        XCTAssertEqual(byID["https:web.example"]?["meshNpub"] as? String, box)
        XCTAssertEqual((byID["https:web.example"]?["updatedAt"] as? NSNumber)?.int64Value, 1_767_000_000)
    }

    /// This device's own entry is left out on apply and never deleted from the file.
    func testOwnEntryLeftOutNotDeleted() throws {
        let (mac, _) = try npubs()
        let file: [Any] = [entry("mesh:" + mac, mesh: mac, order: 0, name: "This Mac"),
                           entry("https:b.example", https: "https://b.example", order: 1)]
        let applied = CopySettings.apply(["desktop_vaults": file], to: HavenConfig(), ownNpub: mac)
        XCTAssertEqual(applied.desktopVaults.map(\.id), ["https:b.example"])
        let out = CopySettings.keys(applied, previousVaults: file, ownNpub: mac, now: now)["desktop_vaults"] as? [Any] ?? []
        XCTAssertEqual(ids(out), ["mesh:" + mac, "https:b.example"])
        XCTAssertNil(CopySettings.vaultEntries(out).first?["deletedAt"])
    }

    /// Order: the file's numbers stay unless the Vaults were reordered here.
    func testOrderKeptUnlessReordered() throws {
        let previous: [Any] = [entry("https:a.example", https: "https://a.example", order: 3),
                               entry("https:b.example", https: "https://b.example", order: 7)]
        var c = HavenConfig()
        c.desktopVaults = [DesktopVault(id: "https:a.example", name: "", httpsURL: "https://a.example", order: 0),
                           DesktopVault(id: "https:b.example", name: "", httpsURL: "https://b.example", order: 1)]
        var out = CopySettings.vaultEntries(CopySettings.keys(c, previousVaults: previous, ownNpub: nil, now: now)["desktop_vaults"] as? [Any])
        XCTAssertEqual(out.compactMap { ($0["updatedAt"] as? NSNumber)?.int64Value }, [1_767_000_000, 1_767_000_000])
        c.desktopVaults = [DesktopVault(id: "https:b.example", name: "", httpsURL: "https://b.example", order: 0),
                           DesktopVault(id: "https:a.example", name: "", httpsURL: "https://a.example", order: 1)]
        out = CopySettings.vaultEntries(CopySettings.keys(c, previousVaults: previous, ownNpub: nil, now: now)["desktop_vaults"] as? [Any])
        XCTAssertEqual(out.compactMap { $0["id"] as? String }, ["https:b.example", "https:a.example"])
        XCTAssertEqual(out.compactMap { ($0["updatedAt"] as? NSNumber)?.int64Value }, [now, now])
    }
}
