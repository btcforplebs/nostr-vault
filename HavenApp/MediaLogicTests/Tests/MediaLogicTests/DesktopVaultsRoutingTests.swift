import XCTest
@testable import MediaLogic

/// Desktop Vaults P3, Apple routing (PLANS/NV_DESKTOP_VAULTS_PLAN.md §2.2,
/// §2.4): the DM inbox and self-copy cover every HTTPS Vault, publish-for-me
/// and the mesh dial take the list in order, the env passes the rest, and a
/// Vault switch changes only its own entry. Plus Tron's N1-N3 on #2499.
final class DesktopVaultsRoutingTests: XCTestCase {
    // Random strings in the npub charset, not real accounts.
    private let macA = "npub1z2g42utgkc5tv49xgwy7lplfd8048vuwv9krcc23m828kdjm3cl68tgcyy"
    private let macB = "npub1h8ts9gragczufl8v44chxgut0a870ranmjws865ejtvphmn0czt7cp5dae"
    private let phone = "npub1" + String(repeating: "q", count: 58)
    private let meshURL = "ws://127.0.0.1:41234/abcdef0123456789"

    private func mac(_ npub: String, _ name: String = "", domain: String? = nil) -> MeshDevice {
        MeshDevice(npub: npub, name: name, role: .mac, domain: domain)
    }

    private func vault(_ id: String, https: String? = nil, mesh: String? = nil, order: Int) -> DesktopVault {
        DesktopVault(id: id, name: "", meshNpub: mesh, httpsURL: https, order: order)
    }

    // MARK: N1, N2: the list follows My Devices

    func testMacPairedAfterMigrationJoinsTheList() {
        var config = HavenConfig()
        config.macRelayURL = "https://web.example.com"
        config.takeInDesktopVaultSlot(ownNpub: nil)
        config.meshDevices = [mac(macA, "Studio")]
        let vaults = config.desktopVaultsInEffect(ownNpub: nil)
        XCTAssertEqual(vaults.map(\.httpsURL), ["https://web.example.com", nil])
        XCTAssertEqual(vaults.map(\.meshNpub), [nil, macA])
        XCTAssertEqual(vaults.last?.name, "Studio")
        XCTAssertEqual(vaults.map(\.order), [0, 1])
    }

    func testRemovedMacLeavesTheList() {
        var config = HavenConfig()
        config.meshDevices = [mac(macA), mac(macB)]
        config.takeInDesktopVaultSlot(ownNpub: nil)
        XCTAssertEqual(config.desktopVaultMeshNpubs(ownNpub: nil), [macA, macB])
        config.meshDevices = [mac(macB)]
        XCTAssertEqual(config.desktopVaultMeshNpubs(ownNpub: nil), [macB])
        // A Vault with a web address keeps it and loses only the mesh path.
        let both = DesktopVaultsLogic.followingDevices([vault("a", https: "https://a.example.com", mesh: macA, order: 0)],
                                                      devices: [], slot: "", ownNpub: nil)
        XCTAssertEqual(both.map(\.httpsURL), ["https://a.example.com"])
        XCTAssertEqual(both.map(\.meshNpub), [nil])
    }

    /// The slot's own npub stays a Vault even when it is no `.mac` device,
    /// as it was before P3.
    func testSlotNpubStaysWithoutADevice() {
        var config = HavenConfig()
        config.macRelayURL = macA
        config.takeInDesktopVaultSlot(ownNpub: nil)
        XCTAssertEqual(config.desktopVaultMeshNpubs(ownNpub: nil), [macA])
    }

    func testOwnNpubIsNeverAVault() {
        var config = HavenConfig()
        config.macRelayURL = macA
        config.meshDevices = [mac(macA), mac(macB)]
        config.takeInDesktopVaultSlot(ownNpub: macA)
        XCTAssertEqual(config.desktopVaults.map(\.meshNpub), [macB])
        // A list stored before this device knew its own npub sheds it.
        var stored = HavenConfig()
        stored.meshDevices = [mac(macA), mac(macB)]
        stored.takeInDesktopVaultSlot(ownNpub: nil)
        XCTAssertEqual(stored.desktopVaultMeshNpubs(ownNpub: macB), [macA])
        // Even when the slot names it (a Mac whose old tab held its own npub).
        var slotted = HavenConfig()
        slotted.macRelayURL = macA
        slotted.takeInDesktopVaultSlot(ownNpub: nil)
        XCTAssertEqual(slotted.desktopVaultMeshNpubs(ownNpub: nil), [macA])
        XCTAssertEqual(slotted.desktopVaultMeshNpubs(ownNpub: macA), [])
    }

    func testPairedMacWithTheVaultsDomainMergesIntoIt() {
        let out = DesktopVaultsLogic.followingDevices([vault("w", https: "https://Mac.Example.com/haven", order: 0)],
                                                     devices: [mac(macA, "Studio", domain: "mac.example.com")],
                                                     slot: "", ownNpub: nil)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.meshNpub, macA)
        XCTAssertEqual(out.first?.httpsURL, "https://Mac.Example.com/haven")
        XCTAssertEqual(out.first?.name, "Studio")
    }

    /// N3: clearing the old tab takes only the slot's address off. A Mac
    /// still in My Devices stays a Vault; removing it there turns it off.
    func testClearingTheOldTabKeepsAPairedMacAndDropsAnUnpairedOne() {
        var config = HavenConfig()
        config.macRelayURL = "https://mac.example.com"
        config.meshDevices = [mac(macA, domain: "mac.example.com")]
        config.takeInDesktopVaultSlot(ownNpub: nil)
        XCTAssertEqual(config.desktopVaults.map(\.meshNpub), [macA])
        config.macRelayURL = ""
        XCTAssertEqual(config.desktopVaultsInEffect(ownNpub: nil).map(\.httpsURL), [nil])
        XCTAssertEqual(config.desktopVaultMeshNpubs(ownNpub: nil), [macA])
        config.meshDevices = []
        XCTAssertEqual(config.desktopVaultsInEffect(ownNpub: nil), [])

        var meshSlot = HavenConfig()
        meshSlot.macRelayURL = macB
        meshSlot.takeInDesktopVaultSlot(ownNpub: nil)
        meshSlot.macRelayURL = ""
        XCTAssertEqual(meshSlot.desktopVaultsInEffect(ownNpub: nil), [])
    }

    // MARK: Publish-for-me and the mesh dial

    func testMeshNpubsFollowListOrderOncePerNpub() {
        let vaults = [vault("b", mesh: macB, order: 1), vault("w", https: "https://w.example.com", order: 0),
                      vault("a", mesh: "fipsmesh://\(macA)/", order: 2), vault("a2", mesh: macA, order: 3)]
        XCTAssertEqual(DesktopVaultsLogic.meshNpubs(vaults), [macB, macA])
    }

    /// A dial for a mesh Vault on the list counts, wherever the slot points;
    /// a dial left from before the list changed does not.
    func testDialedListVaultIsPublishForMeAndMacRelay() {
        var config = HavenConfig()
        config.macRelayURL = "https://web.example.com"
        config.blastrRelays = ["wss://nos.lol"]
        config.meshDevices = [mac(macA)]
        config.takeInDesktopVaultSlot(ownNpub: nil)
        let dialed = RelayConfiguration.MacMeshRelay(npub: macA, url: meshURL)
        XCTAssertEqual(RelayConfiguration.dialedVault(config: config, mesh: dialed), dialed)
        XCTAssertEqual(RelayConfiguration.macRelayURL(config: config, mesh: dialed), meshURL)
        XCTAssertEqual(RelayConfiguration.blastrRelays(config: config, mesh: dialed).first, meshURL + "?pulled=1")
        // The web slot is not lost: it goes to DESKTOP_VAULT_URLS.
        XCTAssertEqual(DesktopVaultsLogic.envList(config.desktopVaultsInEffect, slot: meshURL,
                                                  typed: config.macRelayURL), "wss://web.example.com")

        let stale = RelayConfiguration.MacMeshRelay(npub: macB, url: meshURL)
        XCTAssertNil(RelayConfiguration.dialedVault(config: config, mesh: stale))
        XCTAssertEqual(RelayConfiguration.macRelayURL(config: config, mesh: stale), "wss://web.example.com")
        XCTAssertFalse(RelayConfiguration.blastrRelays(config: config, mesh: stale).contains { $0.hasPrefix("ws://127.0.0.1") })
    }

    // MARK: When the mesh is dialed (Tron M1 on #2506)

    /// Before the start only for a mesh-npub slot; any other mesh Vault is
    /// dialed after a wss start; nothing with FIPS off or no mesh Vault.
    func testMeshDialHoldsTheStartOnlyForAMeshSlot() {
        XCTAssertEqual(DesktopVaultsLogic.meshDial(fipsOn: true, slot: macA, meshNpubs: [macA]), .beforeStart)
        XCTAssertEqual(DesktopVaultsLogic.meshDial(fipsOn: true, slot: "https://web.example.com", meshNpubs: [macA, macB]),
                       .afterStart)
        XCTAssertEqual(DesktopVaultsLogic.meshDial(fipsOn: true, slot: "", meshNpubs: [macA]), .afterStart)
        XCTAssertEqual(DesktopVaultsLogic.meshDial(fipsOn: false, slot: macA, meshNpubs: [macA]), .none)
        XCTAssertEqual(DesktopVaultsLogic.meshDial(fipsOn: false, slot: "https://web.example.com", meshNpubs: [macA]),
                       .none)
        XCTAssertEqual(DesktopVaultsLogic.meshDial(fipsOn: true, slot: "https://web.example.com", meshNpubs: []), .none)
    }

    /// Dials go in list order and the first answer wins.
    func testFirstAnsweringTakesTheFirstThatAnswersInOrder() async {
        let answering = macB
        let found = await DesktopVaultsLogic.firstAnswering([macA, macB], budget: 5) { npub in
            npub == answering ? "ws://127.0.0.1:1/b" : nil
        }
        XCTAssertEqual(found?.npub, macB)
        XCTAssertEqual(found?.url, "ws://127.0.0.1:1/b")
    }

    /// Unreachable Vaults share one budget: three dials that never answer
    /// end with the budget, not three of them, and a later one is not tried.
    func testFirstAnsweringSharesOneBudget() async {
        let tried = Tried()
        let start = Date()
        let found = await DesktopVaultsLogic.firstAnswering([macA, macB, "npub1third"], budget: 0.6) { npub in
            await tried.add(npub)
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            return "ws://127.0.0.1:1/late"
        }
        XCTAssertNil(found)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.0)
        let names = await tried.names
        XCTAssertEqual(names, [macA])
    }

    private actor Tried {
        var names: [String] = []
        func add(_ name: String) { names.append(name) }
    }

    // MARK: The env

    /// A Vault reached over the mesh keeps its wss as the fallback (Tron M2
    /// on #2506: the mesh link ends in the background and nothing re-dials);
    /// a plain ws:// slot keeps ws://.
    func testEnvListKeepsTheDialedVaultsWSSAndPlainWS() {
        let vaults = [vault("a", https: "https://a.example.com", mesh: macA, order: 0),
                      vault("b", https: "https://b.example.com/haven", order: 1),
                      vault("c", https: "https://192.168.1.5:3355", order: 2)]
        XCTAssertEqual(DesktopVaultsLogic.envList(vaults, slot: meshURL, typed: "ws://192.168.1.5:3355"),
                       "wss://a.example.com,wss://b.example.com/haven,ws://192.168.1.5:3355")
        XCTAssertEqual(DesktopVaultsLogic.envList(vaults, slot: "wss://a.example.com"),
                       "wss://b.example.com/haven,wss://192.168.1.5:3355")
    }

    // MARK: DM inbox and self-copy (§2.2 rule 2)

    func testEveryHTTPSVaultIsADMInboxInListOrder() {
        let vaults = [vault("b", https: "https://b.example.com/haven/", order: 1),
                      vault("m", mesh: macA, order: 0),
                      vault("a", https: "https://a.example.com", order: 2),
                      vault("lan", https: "https://192.168.1.9:3355", order: 3),
                      vault("ts", https: "https://mac.tail1234.ts.net", order: 4)]
        XCTAssertEqual(DesktopVaultsLogic.dmInboxURLs(vaults, slot: ""),
                       ["wss://b.example.com/haven/inbox", "wss://a.example.com/inbox"])
        // A slot typed as plain ws:// was never a public inbox and still isn't.
        XCTAssertEqual(DesktopVaultsLogic.dmInboxURLs([vault("p", https: "https://p.example.com", order: 0)],
                                                      slot: "ws://p.example.com"), [])
        XCTAssertEqual(HavenConfig.mergedDMInboxRelays(havenInboxes: ["wss://b.example.com/haven/inbox", "wss://a.example.com/inbox"],
                                                       dmRelays: ["wss://a.example.com/inbox/", "wss://inbox.nostr.wine"]),
                       ["wss://b.example.com/haven/inbox", "wss://a.example.com/inbox", "wss://inbox.nostr.wine"])
    }

    /// A one-slot user's inbox is what the slot gave before P3.
    func testSlotUserKeepsTheirInbox() {
        for slot in ["wss://mac.example.com/", "https://mac.example.com/haven", "mac.example.com"] {
            var config = HavenConfig()
            config.macRelayURL = slot
            config.takeInDesktopVaultSlot(ownNpub: nil)
            XCTAssertEqual(config.desktopVaultDMInboxURLs, ["wss://\(config.macRelayNormalizedBase)/inbox"], slot)
        }
    }

    // MARK: DesktopVaultListEdit's change (§2.5 rule 7)

    func testSwitchChangesOnlyThisVaultsEntryOnTheNewestList() {
        let a = vault("a", https: "https://a.example.com", mesh: macA, order: 0)
        let b = vault("b", https: "https://b.example.com", order: 1)
        let newest = [["relay", "wss://inbox.nostr.wine"], ["relay", "wss://b.example.com/inbox"]]
        XCTAssertEqual(DesktopVaultsLists.switching(true, a, path: .web, in: .inbox, tags: newest, vaults: [a, b]),
                       // In front of b, the next Vault; no existing entry moves (rule 2).
                       .tags([["relay", "wss://inbox.nostr.wine"], ["relay", "wss://a.example.com/inbox"],
                              ["relay", "wss://b.example.com/inbox"]]))
        XCTAssertEqual(DesktopVaultsLists.switching(false, b, path: .web, in: .inbox, tags: newest, vaults: [a, b]),
                       .tags([["relay", "wss://inbox.nostr.wine"]]))
        XCTAssertEqual(DesktopVaultsLists.switching(false, b, path: .web, in: .inbox,
                                                    tags: [["relay", "wss://b.example.com/inbox"]], vaults: [a, b]),
                       .refused(.inbox))
    }

    /// The relays agree there is no list yet: on starts one when it is
    /// usable on its own, off changes nothing.
    func testSwitchWithNoPublishedList() {
        let a = vault("a", https: "https://a.example.com", mesh: macA, order: 0)
        XCTAssertEqual(DesktopVaultsLists.switching(true, a, path: .web, in: .media, tags: nil, vaults: [a]),
                       .tags([["server", "https://a.example.com"]]))
        XCTAssertEqual(DesktopVaultsLists.switching(true, a, path: .mesh, in: .media, tags: nil, vaults: [a]),
                       .refused(.media))
        XCTAssertEqual(DesktopVaultsLists.switching(false, a, path: .web, in: .relays, tags: nil, vaults: [a]),
                       .tags([]))
    }

    // MARK: 10002 saves carry fipsmesh tags over

    func testRelaysSaveKeepsTheNewestListsMeshTagsLast() throws {
        let fips = ["fipsmesh", "fipsmesh://\(macA)/", "write"]
        let tags = [["r", "wss://nostr.land"], fips, ["r", "ws://192.168.1.5:3355"], ["fipsmesh", "not-an-npub"]]
        XCTAssertEqual(DesktopVaultsLists.meshRelayTags(tags), [fips])

        let published = RelayDraft.Published(read: ["wss://nostr.land"], write: ["wss://nostr.land"],
                                             relayListKnown: true, dmListKnown: true,
                                             kept: [["r", "ws://192.168.1.5:3355"]] + DesktopVaultsLists.meshRelayTags(tags))
        let lists = RelayMatrix.Lists(read: ["wss://nostr.land"], write: ["wss://nostr.land"], dms: [], search: [], importing: [])
        var state = RelayDraft.start(lists, published: published, pinned: [])
        state = RelayDraft.toggle(state, key: RelayMatrix.key("wss://nostr.land"), job: .write)
        let out = try XCTUnwrap(RelayDraft.plan(state, ownRelays: [], ownInbox: "").relayListTags)
        XCTAssertEqual(out.last, fips)
        XCTAssertEqual(out.filter { $0.first == "fipsmesh" }, [fips])
    }
}
