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

    // MARK: rolesNaming

    func testOneAddressThatIsTwoSettingsNamesBothRoles() {
        XCTAssertEqual(MeshDevicesLogic.rolesNaming(mac, macNpub: mac, homeVaultNpub: mac, browserNpub: page), [.mac, .homeVault])
        XCTAssertEqual(MeshDevicesLogic.rolesNaming(page, macNpub: mac, homeVaultNpub: mac, browserNpub: page), [.browser])
        XCTAssertEqual(MeshDevicesLogic.rolesNaming(moto, macNpub: mac, homeVaultNpub: home, browserNpub: nil), [])
    }

    /// The Mac that is also the home vault shows once; Remove must clear both
    /// settings or the row comes back under the other role (Tron, PR 974).
    func testRemovingAnAddressThatIsTwoSettingsLeavesNoRow() {
        let stored = [MeshDevice(npub: mac, name: "", role: .mac)]
        XCTAssertEqual(MeshDevicesLogic.merged(stored: stored, macNpub: mac, homeVaultNpub: mac, browserNpub: nil).map(\.role), [.mac])
        var sources: [MeshDeviceRole: String] = [.mac: mac, .homeVault: mac]
        for role in MeshDevicesLogic.rolesNaming(mac, macNpub: sources[.mac], homeVaultNpub: sources[.homeVault], browserNpub: nil) {
            sources[role] = nil
        }
        let after = MeshDevicesLogic.merged(
            stored: MeshDevicesLogic.removing(npub: mac, from: stored),
            macNpub: sources[.mac], homeVaultNpub: sources[.homeVault], browserNpub: nil
        )
        XCTAssertEqual(after, [])
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

    func testAnUnknownRoleDropsOnlyThatEntry() throws {
        let json = #"""
        {"relayPort": 4869, "meshDevices": [
            {"npub": "npub1moto", "name": "Moto", "role": "phone"},
            {"npub": "npub1x", "name": "", "role": "toaster"},
            {"npub": "npub1home", "name": "Pi", "role": "homeVault"}
        ], "meshPhotoDestination": "carrier-pigeon"}
        """#
        let config = try JSONDecoder().decode(HavenConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.relayPort, 4869)
        XCTAssertEqual(config.meshDevices, [
            MeshDevice(npub: moto, name: "Moto", role: .phone),
            MeshDevice(npub: home, name: "Pi", role: .homeVault),
        ])
        XCTAssertEqual(config.photoDestination, .publicServer)
    }

    func testAListThatIsNotAListLoadsEmpty() throws {
        let json = #"{"relayPort": 4869, "meshDevices": "nope"}"#
        let config = try JSONDecoder().decode(HavenConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.relayPort, 4869)
        XCTAssertEqual(config.meshDevices, [])
    }

    // MARK: macEngineOptions

    func testTheMacEngineIsOpenToMyDevicesOnly() throws {
        let devices = [
            MeshDevice(npub: moto, name: "Moto", role: .phone),
            MeshDevice(npub: page, name: "", role: .browser),
            MeshDevice(npub: mac, name: "", role: .mac),
        ]
        let opts = try XCTUnwrap(MeshDevicesLogic.macEngineOptions(devices: devices, ownNpub: mac, relays: ["wss://a"], meshDoorPort: HavenConfig().meshPlainPort))
        XCTAssertEqual(opts["own_devices"] as? [String], [moto, page], "this Mac is never its own device")
        XCTAssertEqual(opts["relays"] as? [String], ["wss://a"])
        XCTAssertNil(opts["peers"])
        // Strangers come in through the seeds, capped, never through an offer.
        XCTAssertEqual(opts["public_seeds"] as? Bool, true)
        // Strangers get Haven's mesh door, never the relay port own devices get.
        let config = HavenConfig()
        XCTAssertEqual(opts["strangers_port"] as? Int, config.meshPlainPort)
        XCTAssertNotEqual(opts["strangers_port"] as? Int, config.relayPort)
        XCTAssertNil(opts["strangers"], "the old switch pointed strangers at the relay port")
        // A phone on the Mac's Wi-Fi links over the LAN, not a hairpin.
        XCTAssertEqual(opts["lan"] as? Bool, true)
        // No valid door port: the engine stays off rather than open strangers anywhere.
        XCTAssertNil(MeshDevicesLogic.macEngineOptions(devices: devices, ownNpub: mac, relays: [], meshDoorPort: 0))
    }

    func testNoDevicesMeansTheMacEngineStaysOff() {
        // An empty own_devices would open the engine to anyone.
        XCTAssertNil(MeshDevicesLogic.macEngineOptions(devices: [], ownNpub: nil, relays: [], meshDoorPort: 3356))
        let onlySelf = [MeshDevice(npub: mac, name: "", role: .mac)]
        XCTAssertNil(MeshDevicesLogic.macEngineOptions(devices: onlySelf, ownNpub: mac, relays: [], meshDoorPort: 3356))
    }

    func testTheMacEngineFallsBackToTheDefaultFinderRelays() throws {
        let opts = try XCTUnwrap(MeshDevicesLogic.macEngineOptions(devices: [MeshDevice(npub: moto, name: "", role: .phone)], ownNpub: nil, relays: [], meshDoorPort: 3356))
        XCTAssertEqual(opts["relays"] as? [String], MeshDevicesLogic.defaultFinderRelays)
    }
}
