import XCTest
@testable import MediaLogic

/// FIPS Mesh → My Devices: one list, kept in step with the settings that
/// already name a device (the Mac, the home vault, the browser page).
final class MeshDevicesTests: XCTestCase {
    private let mac = "npub1mac", home = "npub1home", page = "npub1page", moto = "npub1moto"

    // MARK: merged

    func testSettingsWithNoStoredEntryJoinTheListInRoleOrder() {
        let list = MeshDevicesLogic.merged(stored: [], macNpub: mac, homeVaultNpub: home, browserNpub: page)
        XCTAssertEqual(list.map(\.npub), [mac, home, page])
        XCTAssertEqual(list.map(\.role), [.mac, .homeVault, .browser])
        XCTAssertEqual(list.map(\.name), ["", "", ""])
    }

    func testStoredOrderAndNamesAreKept() {
        let stored = [
            MeshDevice(npub: moto, name: "Moto", role: .phone),
            MeshDevice(npub: mac, name: "Studio Mac", role: .mac),
        ]
        let list = MeshDevicesLogic.merged(stored: stored, macNpub: mac, homeVaultNpub: home, browserNpub: nil)
        XCTAssertEqual(list.map(\.npub), [moto, mac, home])
        XCTAssertEqual(list[1].displayName, "Studio Mac")
    }

    func testAStoredRoleWhoseSettingMovedOnIsDropped() {
        // The home vault was changed (or cleared) elsewhere: the old entry
        // must not stay in the list looking like the home vault.
        let stored = [MeshDevice(npub: "npub1old", name: "Old kiosk", role: .homeVault)]
        let cleared = MeshDevicesLogic.merged(stored: stored, macNpub: nil, homeVaultNpub: nil, browserNpub: nil)
        XCTAssertEqual(cleared, [])
        let moved = MeshDevicesLogic.merged(stored: stored, macNpub: nil, homeVaultNpub: home, browserNpub: nil)
        XCTAssertEqual(moved.map(\.npub), [home])
    }

    func testPhonesNeedNoSetting() {
        let stored = [MeshDevice(npub: moto, name: "", role: .phone)]
        XCTAssertEqual(MeshDevicesLogic.merged(stored: stored, macNpub: nil, homeVaultNpub: nil, browserNpub: nil), stored)
    }

    func testOneAddressIsListedOnce() {
        let stored = [
            MeshDevice(npub: moto, name: "A", role: .phone),
            MeshDevice(npub: moto, name: "B", role: .phone),
        ]
        let list = MeshDevicesLogic.merged(stored: stored, macNpub: nil, homeVaultNpub: nil, browserNpub: nil)
        XCTAssertEqual(list.map(\.name), ["A"])
    }

    // MARK: adding / removing

    func testAddingAKnownAddressChangesItInPlace() {
        let stored = [
            MeshDevice(npub: moto, name: "", role: .phone),
            MeshDevice(npub: mac, name: "", role: .mac),
        ]
        let out = MeshDevicesLogic.adding(MeshDevice(npub: moto, name: "Moto", role: .phone), to: stored)
        XCTAssertEqual(out.map(\.npub), [moto, mac])
        XCTAssertEqual(out[0].name, "Moto")
    }

    func testANewHomeVaultReplacesTheOldOneButPhonesAddUp() {
        let stored = [
            MeshDevice(npub: "npub1old", name: "", role: .homeVault),
            MeshDevice(npub: moto, name: "", role: .phone),
        ]
        let vault = MeshDevicesLogic.adding(MeshDevice(npub: home, name: "", role: .homeVault), to: stored)
        XCTAssertEqual(vault.map(\.npub), [moto, home])
        let phones = MeshDevicesLogic.adding(MeshDevice(npub: "npub1ipad", name: "", role: .phone), to: stored)
        XCTAssertEqual(phones.count, 3)
    }

    func testRemoving() {
        let stored = [MeshDevice(npub: moto, name: "", role: .phone), MeshDevice(npub: mac, name: "", role: .mac)]
        XCTAssertEqual(MeshDevicesLogic.removing(npub: moto, from: stored).map(\.npub), [mac])
    }

    // MARK: status line

    func testStatusLine() {
        XCTAssertEqual(MeshDevicesLogic.statusLine(enabled: false, running: true, inReach: 2, total: 3), "Off")
        XCTAssertEqual(MeshDevicesLogic.statusLine(enabled: true, running: false, inReach: 0, total: 3), "On · starts when needed")
        XCTAssertEqual(MeshDevicesLogic.statusLine(enabled: true, running: true, inReach: 0, total: 0), "On · no devices yet")
        XCTAssertEqual(MeshDevicesLogic.statusLine(enabled: true, running: true, inReach: 3, total: 4), "On · 3 of 4 devices in reach")
    }

    func testInReachCountsOnlyListedDevices() {
        let list = [MeshDevice(npub: mac, name: "", role: .mac), MeshDevice(npub: moto, name: "", role: .phone)]
        XCTAssertEqual(MeshDevicesLogic.inReachCount(list, peers: [mac, "npub1stranger"]), 1)
    }

    // MARK: finder relays

    func testFinderRelayInput() {
        XCTAssertEqual(MeshDevicesLogic.normalizedFinderRelay("relay.example.com/"), "wss://relay.example.com")
        XCTAssertEqual(MeshDevicesLogic.normalizedFinderRelay(" wss://relay.example.com "), "wss://relay.example.com")
        XCTAssertEqual(MeshDevicesLogic.normalizedFinderRelay("ws://192.168.1.5:7777"), "ws://192.168.1.5:7777")
        XCTAssertNil(MeshDevicesLogic.normalizedFinderRelay("https://relay.example.com"))
        XCTAssertNil(MeshDevicesLogic.normalizedFinderRelay(""))
        XCTAssertNil(MeshDevicesLogic.normalizedFinderRelay("wss://"))
    }

    // MARK: config

    func testOldConfigLoadsWithNoDevicesAndThePublicPhotoDefault() throws {
        let config = try JSONDecoder().decode(HavenConfig.self, from: Data("{}".utf8))
        XCTAssertEqual(config.meshDevices, [])
        XCTAssertEqual(config.photoDestination, .publicServer)
    }

    func testDevicesRoundTrip() throws {
        var config = HavenConfig()
        config.meshDevices = [MeshDevice(npub: moto, name: "Moto", role: .phone)]
        config.photoDestination = .both
        let back = try JSONDecoder().decode(HavenConfig.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(back.meshDevices, config.meshDevices)
        XCTAssertEqual(back.photoDestination, .both)
    }

    func testAnUnknownRoleDropsTheListNotTheConfig() throws {
        let json = #"{"relayPort": 4869, "meshDevices": [{"npub": "npub1x", "name": "", "role": "toaster"}], "meshPhotoDestination": "carrier-pigeon"}"#
        let config = try JSONDecoder().decode(HavenConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.relayPort, 4869)
        XCTAssertEqual(config.meshDevices, [])
        XCTAssertEqual(config.photoDestination, .publicServer)
    }
}
