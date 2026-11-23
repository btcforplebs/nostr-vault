import XCTest
@testable import MediaLogic

/// "Your desktop Vault": which desktop a phone reads, and the hand-off names.
final class DesktopVaultPickTests: XCTestCase {
    private let macA = "npub1macaaaa", macB = "npub1macbbbb", phone = "npub1phone"

    private func device(_ npub: String, _ role: MeshDeviceRole, _ name: String = "") -> MeshDevice {
        MeshDevice(npub: npub, name: name, role: role)
    }

    func testTheLatestCaughtUpDesktopIsPicked() {
        let devices = [device(phone, .phone), device(macA, .mac, "Studio"), device(macB, .mac, "Box")]
        XCTAssertEqual(DesktopVaultPick.desktop(devices, lastSync: [macA: 100, macB: 200, phone: 900])?.npub, macB)
        XCTAssertEqual(DesktopVaultPick.desktop(devices, lastSync: [macA: 300, macB: 200])?.npub, macA)
        XCTAssertEqual(DesktopVaultPick.desktop(devices, lastSync: [:])?.npub, macA, "never caught up: the first desktop")
        XCTAssertNil(DesktopVaultPick.desktop([device(phone, .phone)], lastSync: [phone: 5]), "phones are never a desktop")
        XCTAssertNil(DesktopVaultPick.desktop([], lastSync: [:]))
    }

    func testHandoffNames() {
        let hex = String(repeating: "a", count: 64)
        let npub = Bech32.encode(hrp: "npub", data: Data(repeating: 0xaa, count: 32))
        let h = VaultStatus.Handoff(device: hex, role: "phone", tookAt: 1, builtAt: 1, checkedAt: 1)
        XCTAssertEqual(DesktopVaultPick.handoffName(h, devices: [], selfHex: hex.uppercased()), "This device")
        XCTAssertEqual(DesktopVaultPick.handoffName(h, devices: [device(npub ?? "", .phone, "Logen's iPad")], selfHex: nil), "Logen's iPad")
        XCTAssertEqual(DesktopVaultPick.handoffName(h, devices: [], selfHex: nil), "Phone")
        var unknown = h
        unknown.role = nil
        XCTAssertEqual(DesktopVaultPick.handoffName(unknown, devices: [], selfHex: nil), "A paired device")
        XCTAssertEqual(DesktopVaultPick.updated(940, now: Date(timeIntervalSince1970: 1000)), "Updated 1 min ago")
    }
}
