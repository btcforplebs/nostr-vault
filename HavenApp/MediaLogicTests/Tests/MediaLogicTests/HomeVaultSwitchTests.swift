import XCTest
@testable import MediaLogic

/// Switching the home vault keeps the old one in My Devices, and the owner's
/// 10063 as it was (2026-10-22: the iPhone moved its home vault from the Mac
/// to the Moto and the new list named only the Moto; since 2026-11-08 only
/// Media Servers changes the list's mesh entries).
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

    /// Switching the home vault, or removing one, writes nothing to the
    /// list: its mesh entries stay until removed on Media Servers.
    func testSwitchingOrRemovingAVaultLeavesTheListAlone() {
        let existing = ["https://a.example/", mesh(mac)]
        XCTAssertEqual(HomeVaultLogic.mergeServerList(existing: existing, current: ["https://a.example/"],
                                                      previouslyManaged: Set(existing), ownMeshNpub: me), existing)
    }
}
