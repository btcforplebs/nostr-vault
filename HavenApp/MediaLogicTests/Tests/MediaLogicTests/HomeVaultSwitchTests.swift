import XCTest
@testable import MediaLogic

/// Switching the home vault keeps the old one listed in the owner's 10063
/// while it is still in My Devices (2026-10-22: the iPhone moved its home
/// vault from the Mac to the Moto, the new list named only the Moto, and the
/// share page could not reach the photo on the Mac).
final class HomeVaultSwitchTests: XCTestCase {
    private let mac = "npub1" + String(repeating: "m", count: 58)
    private let moto = "npub1" + String(repeating: "t", count: 58)
    private let me = "npub1" + String(repeating: "p", count: 58)
    private func mesh(_ n: String) -> String { "fipsmesh://\(n)/" }

    func testTheOldHomeVaultStaysInMyDevicesAsAPlainDevice() {
        let stored = [MeshDevice(npub: mac, name: "Mac", role: .homeVault)]
        let out = MeshDevicesLogic.adding(MeshDevice(npub: moto, name: "Moto", role: .homeVault), to: stored)
        XCTAssertEqual(out.map(\.npub), [mac, moto])
        XCTAssertEqual(out.map(\.role), [.phone, .homeVault])
        XCTAssertEqual(out[0].name, "Mac", "keeps its name")
        // My Devices still shows both once the setting names the Moto.
        let shown = MeshDevicesLogic.merged(stored: out, macNpub: nil, homeVaultNpub: moto, browserNpub: nil)
        XCTAssertEqual(Set(shown.map(\.npub)), [mac, moto])
    }

    func testAnEntryListedBeforeStaysWhileItIsStillInMyDevices() {
        let before = ["https://a.example/", mesh(mac)]
        XCTAssertEqual(HomeVaultLogic.stillOwnedMeshEntries(previouslyManaged: before, myDevices: [mac, moto]), [mesh(mac)])
        XCTAssertEqual(HomeVaultLogic.stillOwnedMeshEntries(previouslyManaged: before, myDevices: [moto]), [],
                       "removed from My Devices: unlisted")
        XCTAssertEqual(HomeVaultLogic.stillOwnedMeshEntries(previouslyManaged: before, myDevices: ["fipsmesh://\(mac)/"]),
                       [mesh(mac)], "any address form names the device")
    }

    /// The whole switch, as publishServerList runs it on the iPhone.
    func testSwitchingMacToMotoListsBoth() {
        let managedBefore = ["https://a.example/", mesh(mac)]
        let existing = managedBefore  // the newest list is the one this phone published
        let devices = MeshDevicesLogic.adding(MeshDevice(npub: moto, name: "", role: .homeVault),
                                              to: [MeshDevice(npub: mac, name: "", role: .homeVault)])
        let myDevices = MeshDevicesLogic.merged(stored: devices, macNpub: nil, homeVaultNpub: moto, browserNpub: nil).map(\.npub)
        var current = ["https://a.example/", mesh(moto)]
        current += HomeVaultLogic.stillOwnedMeshEntries(previouslyManaged: managedBefore, myDevices: myDevices)
        let out = HomeVaultLogic.mergeServerList(existing: existing, current: current,
                                                 previouslyManaged: Set(managedBefore), ownMeshNpub: me)
        XCTAssertEqual(out, ["https://a.example/", mesh(mac), mesh(moto)])

        // Later, Remove on the old vault: the next list drops it.
        let afterRemove = MeshDevicesLogic.removing(npub: mac, from: devices)
        let left = MeshDevicesLogic.merged(stored: afterRemove, macNpub: nil, homeVaultNpub: moto, browserNpub: nil).map(\.npub)
        var next = ["https://a.example/", mesh(moto)]
        next += HomeVaultLogic.stillOwnedMeshEntries(previouslyManaged: current, myDevices: left)
        XCTAssertEqual(HomeVaultLogic.mergeServerList(existing: out!, current: next, previouslyManaged: Set(current), ownMeshNpub: me),
                       ["https://a.example/", mesh(moto)])
    }
}
