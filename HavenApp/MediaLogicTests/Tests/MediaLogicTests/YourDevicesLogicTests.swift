import XCTest
@testable import MediaLogic

/// Settings › Your Devices: which card gets Sync now, and its status line.
final class YourDevicesLogicTests: XCTestCase {
    private let mac = MeshDevice(npub: "npub1mac", name: "", role: .mac)
    private let kiosk = MeshDevice(npub: "npub1kiosk", name: "", role: .homeVault)
    private let phone = MeshDevice(npub: "npub1phone", name: "", role: .phone)
    private let browser = MeshDevice(npub: "npub1web", name: "", role: .browser)

    func testOnlyVaultsGetSyncNow() {
        XCTAssertEqual(YourDevicesLogic.syncAction(mac, macSet: true, homeVaultNpub: "npub1kiosk"), .desktopVault)
        XCTAssertEqual(YourDevicesLogic.syncAction(kiosk, macSet: true, homeVaultNpub: "npub1kiosk"), .mobileVault)
        XCTAssertNil(YourDevicesLogic.syncAction(phone, macSet: true, homeVaultNpub: "npub1kiosk"))
        XCTAssertNil(YourDevicesLogic.syncAction(browser, macSet: true, homeVaultNpub: "npub1kiosk"))
    }

    /// The desktop vault check runs against the Mac this phone has set; a
    /// mobile vault's Sync now sends to the one this phone sends to.
    func testSyncNowNeedsTheVaultThisPhoneUses() {
        XCTAssertNil(YourDevicesLogic.syncAction(mac, macSet: false, homeVaultNpub: nil))
        XCTAssertNil(YourDevicesLogic.syncAction(kiosk, macSet: true, homeVaultNpub: "npub1other"))
        XCTAssertNil(YourDevicesLogic.syncAction(kiosk, macSet: true, homeVaultNpub: nil))
    }

    func testStatusLine() {
        XCTAssertEqual(YourDevicesLogic.statusLine(mac, peers: nil), "Desktop vault · full history")
        XCTAssertEqual(YourDevicesLogic.statusLine(mac, peers: ["npub1mac"]), "Desktop vault · full history · in reach")
        XCTAssertEqual(YourDevicesLogic.statusLine(phone, peers: ["npub1mac"]), "Phone · not in reach now")
    }
}
