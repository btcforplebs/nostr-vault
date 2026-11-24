import XCTest
@testable import MediaLogic

/// Multi-Mac rules (RESEARCH/NV_MULTI_DEVICE_MEDIA_SYNC_RULES.md), step 1:
/// many Macs in My Devices, one lane per Mac, the full-copy switch and the
/// one web device.
final class MultiMacLogicTests: XCTestCase {
    private let macA = "npub1maca", macB = "npub1macb", box = "npub1box", home = "npub1home", moto = "npub1moto", me = "npub1me"

    private func dev(_ npub: String, _ role: MeshDeviceRole, domain: String? = nil) -> MeshDevice {
        MeshDevice(npub: npub, name: "", role: role, domain: domain)
    }

    // MARK: My Devices keeps every Mac

    func testMergedKeepsAMacTheSettingDoesNotName() {
        let stored = [dev(macA, .mac), dev(moto, .phone), dev(macB, .mac)]
        let list = MeshDevicesLogic.merged(stored: stored, macNpub: macA, homeVaultNpub: nil, browserNpub: nil)
        XCTAssertEqual(list.map(\.npub), [macA, moto, macB])
        // The setting cleared (or moved to another Mac): every stored Mac stays.
        XCTAssertEqual(MeshDevicesLogic.merged(stored: stored, macNpub: nil, homeVaultNpub: nil, browserNpub: nil).map(\.npub),
                       [macA, moto, macB])
        XCTAssertEqual(MeshDevicesLogic.merged(stored: stored, macNpub: box, homeVaultNpub: nil, browserNpub: nil).map(\.npub),
                       [macA, moto, macB, box], "a Mac set only in the setting gets a card")
    }

    func testAddingMacsAddsUpAndReAddingChangesInPlace() {
        var list = MeshDevicesLogic.adding(dev(macA, .mac), to: [])
        list = MeshDevicesLogic.adding(dev(macB, .mac), to: list)
        list = MeshDevicesLogic.adding(dev(box, .mac), to: list)
        XCTAssertEqual(list.map(\.npub), [macA, macB, box])
        list = MeshDevicesLogic.adding(MeshDevice(npub: macB, name: "Studio", role: .mac, domain: "b.example"), to: list)
        XCTAssertEqual(list.map(\.npub), [macA, macB, box])
        XCTAssertEqual(list[1].name, "Studio")
        XCTAssertEqual(list[1].domain, "b.example")
    }

    func testMacsPutsTheSettingFirstAndNeverThisDevice() {
        let devices = [dev(macB, .mac), dev(moto, .phone), dev(macA, .mac), dev(me, .mac), dev(macB, .mac)]
        XCTAssertEqual(MeshDevicesLogic.macs(devices, macNpub: macA, ownNpub: me), [macA, macB])
        XCTAssertEqual(MeshDevicesLogic.macs(devices, macNpub: nil, ownNpub: me), [macB, macA])
        XCTAssertEqual(MeshDevicesLogic.macs(devices, macNpub: me, ownNpub: me), [macB, macA], "a Mac never sends to itself")
        XCTAssertEqual(MeshDevicesLogic.macs([], macNpub: nil, ownNpub: me), [])
    }

    func testRemovingTheSettingsMacHandsTheSettingToTheNextMac() {
        let devices = [dev(moto, .phone), dev(macA, .mac), dev(macB, .mac)]
        XCTAssertEqual(MeshDevicesLogic.macSettingAfterRemoving(macA, devices: devices, macNpub: macA), macB)
        XCTAssertEqual(MeshDevicesLogic.macSettingAfterRemoving(macB, devices: devices, macNpub: macA), macA, "another Mac leaves the setting alone")
        XCTAssertNil(MeshDevicesLogic.macSettingAfterRemoving(macA, devices: [dev(macA, .mac)], macNpub: macA))
        XCTAssertNil(MeshDevicesLogic.macSettingAfterRemoving(moto, devices: devices, macNpub: nil))
    }

    func testAnEntrySavedBeforeDomainsStillDecodes() throws {
        let old = #"{"npub":"npub1maca","name":"Mac","role":"mac"}"#.data(using: .utf8)!
        let d = try JSONDecoder().decode(MeshDevice.self, from: old)
        XCTAssertEqual(d.npub, macA)
        XCTAssertNil(d.domain)
        let round = try JSONDecoder().decode(MeshDevice.self, from: JSONEncoder().encode(dev(macA, .mac, domain: "a.example")))
        XCTAssertEqual(round.domain, "a.example")
    }

    // MARK: One lane per Mac (rule 1)

    func testEveryMacGetsALaneButTheMediaVaultsOwn() {
        let devices = [dev(moto, .phone), dev(macA, .mac), dev(macB, .mac), dev(box, .mac)]
        // No home vault: the media vault lane is the Mac setting's Mac.
        XCTAssertEqual(HomeVaultLogic.macTargets(devices: devices, ownNpub: me, mediaVault: macA, mac: macA), [macB, box])
        // A home vault: it is the media vault lane, so every Mac gets its own.
        XCTAssertEqual(HomeVaultLogic.macTargets(devices: devices + [dev(home, .homeVault)], ownNpub: me, mediaVault: home, mac: macA),
                       [macA, macB, box])
        XCTAssertEqual(HomeVaultLogic.macTargets(devices: [dev(moto, .phone)], ownNpub: me, mediaVault: nil, mac: nil), [])
    }

    func testLaneTargetsAreMacsThenPhonesEachOnce() {
        let devices = [dev(moto, .phone), dev(macA, .mac), dev("npub1ipad", .phone), dev(macB, .mac), dev(me, .phone), dev(home, .homeVault)]
        let lanes = HomeVaultLogic.laneTargets(devices: devices, ownNpub: me, homeVault: home, mediaVault: home, mac: macA)
        XCTAssertEqual(lanes, [macA, macB, moto, "npub1ipad"])
        XCTAssertFalse(lanes.contains(home), "the home vault has the media vault lane")
        XCTAssertFalse(lanes.contains(me))
        // Today's single-Mac phone: unchanged, the Mac stays on the media vault lane.
        XCTAssertEqual(HomeVaultLogic.laneTargets(devices: [dev(macA, .mac), dev(moto, .phone)], ownNpub: me,
                                                  homeVault: nil, mediaVault: macA, mac: macA), [moto])
    }

    // MARK: Full copy (§3, Logen's pick 1)

    func testWhoKeepsAFullCopy() {
        XCTAssertTrue(YourDevicesLogic.keepsFullCopy(isDesktop: true, mobileVault: false, stored: false), "Macs always")
        XCTAssertTrue(YourDevicesLogic.keepsFullCopy(isDesktop: false, mobileVault: true, stored: false), "mobile vaults always")
        XCTAssertTrue(YourDevicesLogic.keepsFullCopy(isDesktop: false, mobileVault: false, stored: true))
        XCTAssertFalse(YourDevicesLogic.keepsFullCopy(isDesktop: false, mobileVault: false, stored: false))
        XCTAssertTrue(YourDevicesLogic.keepsFullCopy(isDesktop: false, mobileVault: false, stored: nil),
                      "every phone, new or existing, starts on (Logen's pick 1)")
        XCTAssertTrue(YourDevicesLogic.fullCopyLocked(mobileVault: true))
        XCTAssertFalse(YourDevicesLogic.fullCopyLocked(mobileVault: false))
    }

    func testCatchUpMovesFilesOnlyForFullCopiesAndWiFiOnlyHolds() {
        XCTAssertFalse(YourDevicesLogic.catchUpMovesFiles(fullCopy: false, isDesktop: false, wifiOnly: nil, onWiFi: true), "light: notes only")
        XCTAssertTrue(YourDevicesLogic.catchUpMovesFiles(fullCopy: true, isDesktop: false, wifiOnly: nil, onWiFi: true))
        XCTAssertFalse(YourDevicesLogic.catchUpMovesFiles(fullCopy: true, isDesktop: false, wifiOnly: nil, onWiFi: false), "Wi-Fi only defaults on")
        XCTAssertTrue(YourDevicesLogic.catchUpMovesFiles(fullCopy: true, isDesktop: false, wifiOnly: false, onWiFi: false))
        XCTAssertTrue(YourDevicesLogic.catchUpMovesFiles(fullCopy: true, isDesktop: true, wifiOnly: true, onWiFi: false), "a Mac ignores Wi-Fi only")
    }

    func testTheSwitchesSurviveASaveAndAnOldConfigReadsUnset() throws {
        var config = HavenConfig()
        XCTAssertNil(config.keepFullCopy)
        XCTAssertNil(config.fullCopyWifiOnly)
        config.keepFullCopy = true
        config.fullCopyWifiOnly = false
        let back = try JSONDecoder().decode(HavenConfig.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(back.keepFullCopy, true)
        XCTAssertEqual(back.fullCopyWifiOnly, false)
    }

    // MARK: Public on the web (Desktop Vaults §2.5 rule 3)

    private let domains = ["npub1maca": "a.example.com", "npub1macb": "b.example.com"]

    func testEveryOwnDomainTheNewestListNamesIsMarked() {
        XCTAssertEqual(YourDevicesLogic.publicOnWeb(serverList: ["https://blossom.primal.net", "https://A.example.com/", "https://b.example.com"],
                                                    domains: domains), [macA, macB], "two Vaults both public: both marked")
        XCTAssertEqual(YourDevicesLogic.publicOnWeb(serverList: ["https://b.example.com", "fipsmesh://npub1maca/"], domains: domains), [macB],
                       "a mesh entry is not public on the web")
        XCTAssertEqual(YourDevicesLogic.publicOnWeb(serverList: ["https://blossom.primal.net"], domains: domains), [], "outside servers aren't devices")
        XCTAssertEqual(YourDevicesLogic.publicOnWeb(serverList: ["http://a.example.com"], domains: domains), [], "https only")
        XCTAssertEqual(YourDevicesLogic.publicOnWeb(serverList: [], domains: domains), [])
    }

    func testTwoDevicesWithOneDomainAreBothMarked() {
        let same = ["npub1macb": "a.example.com", "npub1maca": "a.example.com", "npub1macc": "c.example.com"]
        XCTAssertEqual(YourDevicesLogic.publicOnWeb(serverList: ["https://a.example.com"], domains: same), ["npub1maca", "npub1macb"])
    }
}

/// WEB_DOMAIN_PROOF (multi-Mac rules §3.3): the Mac's host for its own devices,
/// never an address.
final class WebDomainForOwnDevicesTests: XCTestCase {
    private func domain(_ relayURL: String) -> String {
        var c = HavenConfig()
        c.relayURL = relayURL
        return c.webDomainForOwnDevices
    }

    func testOnlyAPublicNameIsSent() {
        XCTAssertEqual(domain("wss://Vault.Example.com"), "vault.example.com")
        XCTAssertEqual(domain("vault.example.com:8443"), "vault.example.com")
        XCTAssertEqual(domain("https://vault.example.com/"), "vault.example.com")
        XCTAssertEqual(domain(""), "", "mesh only")
        XCTAssertEqual(domain("localhost:3355"), "")
        XCTAssertEqual(domain("127.0.0.1"), "")
        XCTAssertEqual(domain("192.168.1.20:3355"), "")
        XCTAssertEqual(domain("8.8.8.8"), "", "no IPs, ever")
        XCTAssertEqual(domain("[2001:db8::1]:3355"), "")
        XCTAssertEqual(domain("mac.local"), "")
    }

    func testSentWhetherOrNotPublicOnTheWebIsOn() {
        var c = HavenConfig()
        c.relayURL = "vault.example.com"
        c.publicOnWeb = false
        XCTAssertEqual(c.webDomainForOwnDevices, "vault.example.com", "another Mac must be able to offer the move back")
    }
}
