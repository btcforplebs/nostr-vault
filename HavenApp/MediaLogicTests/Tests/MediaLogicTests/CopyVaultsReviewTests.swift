import XCTest
@testable import MediaLogic

/// Tron's review of #2521 (Desktop Vaults P10): what this device can't hold
/// is carried, an unwritten edit here survives a foreign file, and an empty
/// Vault list is left out for older engines.
final class CopyVaultsReviewTests: XCTestCase {
    private let now: Int64 = 1_767_000_300

    private func npubs() throws -> (mac: String, box: String) {
        let cases = try XCTUnwrap(MeshCopyV2Tests.fixture("settings-refuse-cases")["cases"] as? [[String: Any]])
        let clean = try XCTUnwrap(cases.first { $0["name"] as? String == "vault list, clean" })
        let list = try XCTUnwrap(((clean["settings"] as? [String: Any])?["keys"] as? [String: Any])?["desktop_vaults"] as? [[String: Any]])
        return (try XCTUnwrap(list[0]["meshNpub"] as? String), try XCTUnwrap(list[1]["meshNpub"] as? String))
    }

    private func vault(_ id: String, mesh: String? = nil, https: String? = nil, order: Int = 0,
                       at: Int64 = 1_767_000_000) -> [String: Any] {
        var e: [String: Any] = ["id": id, "name": "", "kind": "mac", "order": order, "updatedAt": at]
        if let mesh { e["meshNpub"] = mesh }
        if let https { e["httpsURL"] = https }
        return e
    }

    /// A Vault whose mesh address is paired here as a phone (not a Mac):
    /// followingDevices drops the address, so the export must carry it as
    /// the file has it, never strip it or tombstone the Vault.
    func testAddressPairedUnderAnotherRoleIsCarriedNotDeleted() throws {
        let (_, box) = try npubs()
        var c = HavenConfig()
        c.meshDevices = [MeshDevice(npub: box, name: "Phone", role: .phone)]
        let fileOnly = vault("mesh:" + box, mesh: box)
        let withWeb = vault("https:box.example", mesh: box, https: "https://box.example", order: 1)
        c.desktopVaults = [DesktopVault(id: "https:box.example", name: "", httpsURL: "https://box.example", order: 0)]
        XCTAssertEqual(c.desktopVaultsInEffect(ownNpub: nil).compactMap(\.meshNpub), [], "positive control: the address is dropped here")
        let previous: [Any] = [fileOnly, withWeb]
        let out = CopySettings.vaultEntries(CopySettings.keys(c, previousVaults: previous, ownNpub: nil, now: now)["desktop_vaults"] as? [Any])
        let byID = Dictionary(uniqueKeysWithValues: out.compactMap { e in (e["id"] as? String).map { ($0, e) } })
        XCTAssertNil(byID[fileOnly["id"] as! String]?["deletedAt"], "a Vault it can't hold was tombstoned")
        XCTAssertEqual(byID[fileOnly["id"] as! String]?["meshNpub"] as? String, box)
        XCTAssertEqual(byID["https:box.example"]?["meshNpub"] as? String, box, "the address was stripped")
    }

    /// The same set followingDevices keeps: a Mac and the slot, never this
    /// device, never a phone.
    func testHoldableIsWhatFollowingDevicesKeeps() throws {
        let (mac, box) = try npubs()
        let devices = [MeshDevice(npub: mac, name: "Mac", role: .mac), MeshDevice(npub: box, name: "Phone", role: .phone)]
        XCTAssertEqual(DesktopVaultsLogic.holdableMeshNpubs(devices: devices, slot: "", ownNpub: nil), [mac])
        XCTAssertEqual(DesktopVaultsLogic.holdableMeshNpubs(devices: devices, slot: "", ownNpub: mac), [])
    }

    /// The engine stored a peer's file (zaps_only changed there) while a
    /// setting changed here (new_posts_pill) and wasn't written yet: only
    /// the peer's change is taken in, so the edit here isn't reverted.
    func testForeignFileTakesInOnlyWhatChangedThere() throws {
        var before = HavenConfig()
        before.zapsOnlyMode = false
        before.showNewPostsPill = true
        before.desktopVaults = [DesktopVault(id: "https:a.example", name: "", httpsURL: "https://a.example", order: 0)]
        let base = CopySettings.keys(before, ownNpub: nil, now: now)
        var theirs = base
        theirs["zaps_only"] = true
        let b = vault("https:b.example", https: "https://b.example", order: 1, at: now)
        theirs["desktop_vaults"] = (base["desktop_vaults"] as? [Any] ?? []) + [b]
        var edited = before
        edited.showNewPostsPill = false
        let changed = CopySettings.changedKeys(theirs, since: base)
        XCTAssertEqual(Set(changed.keys), ["zaps_only", "desktop_vaults"])
        XCTAssertEqual(CopySettings.vaultEntries(changed["desktop_vaults"] as? [Any]).compactMap { $0["id"] as? String },
                       ["https:b.example"], "only the Vault that changed there")
        let applied = CopySettings.apply(changed, to: edited, ownNpub: nil)
        XCTAssertTrue(applied.zapsOnlyMode, "the peer's change was not taken in")
        XCTAssertFalse(applied.showNewPostsPill, "the edit here was reverted")
        XCTAssertEqual(applied.desktopVaults.map(\.id), ["https:a.example", "https:b.example"])
        // Positive control: applying the whole file reverts the edit (the old path).
        XCTAssertTrue(CopySettings.apply(theirs, to: edited, ownNpub: nil).showNewPostsPill)
        // No base yet: everything is taken in.
        XCTAssertEqual(Set(CopySettings.changedKeys(theirs, since: nil).keys), Set(theirs.keys))
    }

    /// Pre-P10 engines refuse `desktop_vaults` as unknown_key, so an empty
    /// list is never written.
    func testEmptyVaultListIsLeftOut() {
        XCTAssertNil(CopySettings.keys(HavenConfig(), ownNpub: nil, now: now)["desktop_vaults"])
        var c = HavenConfig()
        c.desktopVaults = [DesktopVault(id: "https:a.example", name: "", httpsURL: "https://a.example", order: 0)]
        XCTAssertNotNil(CopySettings.keys(c, ownNpub: nil, now: now)["desktop_vaults"])
    }
}
