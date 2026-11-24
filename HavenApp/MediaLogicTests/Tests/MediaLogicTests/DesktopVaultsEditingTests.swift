import XCTest
@testable import MediaLogic

/// Desktop Vaults P4, the Apple screens' rules (PLANS/NV_DESKTOP_VAULTS_PLAN.md
/// §2.4, §2.5 rules 4, 5, 8): add, change an address, drag, delete (and that a
/// deleted Vault stays deleted, Tron N3 on #2499), the bare-IP refusal, and a
/// Relays Save that carries the Vault entries through as published.
final class DesktopVaultsEditingTests: XCTestCase {
    // Random strings in the npub charset, not real accounts.
    private let macA = "npub1z2g42utgkc5tv49xgwy7lplfd8048vuwv9krcc23m828kdjm3cl68tgcyy"
    private let macB = "npub1h8ts9gragczufl8v44chxgut0a870ranmjws865ejtvphmn0czt7cp5dae"

    private func mac(_ npub: String, _ name: String = "", domain: String? = nil) -> MeshDevice {
        MeshDevice(npub: npub, name: name, role: .mac, domain: domain)
    }

    private func migrated(slot: String, devices: [MeshDevice] = []) -> HavenConfig {
        var config = HavenConfig()
        config.macRelayURL = slot
        config.meshDevices = devices
        config.takeInDesktopVaultSlot(ownNpub: nil)
        return config
    }

    // MARK: Delete stays deleted (N3)

    func testADeletedMacVaultStaysOffWhileTheMacIsStillPaired() {
        var config = migrated(slot: macA, devices: [mac(macA, "Studio"), mac(macB, "Attic")])
        XCTAssertEqual(config.desktopVaultMeshNpubs(ownNpub: nil), [macA, macB])
        let id = config.desktopVaultsInEffect(ownNpub: nil).first { $0.meshNpub == macA }!.id
        config.deleteDesktopVault(id: id)
        config.takeInDesktopVaultSlot(ownNpub: nil)
        // Neither the slot naming it nor My Devices brings it back.
        XCTAssertEqual(config.macRelayURL, macA, "the old slot is never written")
        XCTAssertEqual(config.desktopVaultMeshNpubs(ownNpub: nil), [macB])
        XCTAssertEqual(config.macRelayURLInEffect, "")
        XCTAssertNil(config.macRelayMeshNpub)
    }

    func testDeletingTheWebSlotsVaultTurnsOffEverythingDerivedFromTheSlot() {
        var config = migrated(slot: "https://vault.example.com")
        XCTAssertEqual(config.macRelayWssURL, "wss://vault.example.com")
        config.deleteDesktopVault(id: config.desktopVaultsInEffect(ownNpub: nil)[0].id)
        config.takeInDesktopVaultSlot(ownNpub: nil)
        XCTAssertEqual(config.macRelayURL, "https://vault.example.com")
        XCTAssertTrue(config.desktopVaultsInEffect(ownNpub: nil).isEmpty)
        XCTAssertEqual(config.macRelayWssURL, "")
        XCTAssertEqual(config.macRelayHttpsURL, "")
        XCTAssertEqual(config.desktopVaultDMInboxURLs, [])
        XCTAssertEqual(config.desktopVaultWssURLs, [])
    }

    func testAddingTheAddressAgainOrPairingAgainUndoesTheDelete() {
        var config = migrated(slot: "https://vault.example.com", devices: [mac(macA, "Studio")])
        for vault in config.desktopVaultsInEffect(ownNpub: nil) { config.deleteDesktopVault(id: vault.id) }
        XCTAssertTrue(config.desktopVaultsInEffect(ownNpub: nil).isEmpty)

        guard case .success(let web) = DesktopVaultsEditing.adding(
            name: "Home", httpsTyped: "vault.example.com", meshNpub: nil, kind: .linux,
            to: config.desktopVaultsInEffect(ownNpub: nil), ownNpub: nil) else { return XCTFail() }
        config.addDesktopVault(web)
        XCTAssertEqual(config.desktopVaultsInEffect(ownNpub: nil).map(\.httpsURL), ["https://vault.example.com"])
        XCTAssertEqual(config.macRelayURLInEffect, "https://vault.example.com")

        config.forgetRemovedDesktopVault(meshNpub: macA)
        XCTAssertEqual(config.desktopVaultMeshNpubs(ownNpub: nil), [macA])
    }

    /// Tron must-fix 1 on #2511: a Vault keeps its id when its address
    /// changes, so a Vault added later at the old address must get its own.
    func testAVaultAddedAtAMovedVaultsOldAddressGetsItsOwnIdAndDeletesAlone() {
        var config = migrated(slot: "https://old.example.com")
        let first = config.desktopVaultsInEffect(ownNpub: nil)[0].id
        XCTAssertNil(config.setDesktopVaultAddress(id: first, to: "new.example.com"))
        guard case .success(let second) = DesktopVaultsEditing.adding(
            name: "Second", httpsTyped: "old.example.com", meshNpub: nil, kind: .linux,
            to: config.desktopVaultsInEffect(ownNpub: nil), ownNpub: nil) else { return XCTFail() }
        config.addDesktopVault(second)
        let vaults = config.desktopVaultsInEffect(ownNpub: nil)
        XCTAssertEqual(vaults.count, 2)
        XCTAssertEqual(Set(vaults.map(\.id)).count, 2, "every Vault has its own id")

        config.deleteDesktopVault(id: second.id)
        XCTAssertEqual(config.desktopVaultsInEffect(ownNpub: nil).map(\.httpsURL), ["https://new.example.com"])
        XCTAssertFalse(config.desktopVaultsRemoved.contains(DesktopVaultsEditing.removedKey(host: "new.example.com")))
        XCTAssertEqual(config.macRelayURLInEffect, "", "the old slot stays off")
    }

    func testFreshIDCountsUpPastTakenIds() {
        let taken = ["https:a.example.com", "https:a.example.com#2"].enumerated().map {
            DesktopVault(id: $1, name: "", httpsURL: "https://x\($0).example.com", order: $0)
        }
        XCTAssertEqual(DesktopVaultsEditing.freshID("https:b.example.com", in: taken), "https:b.example.com")
        XCTAssertEqual(DesktopVaultsEditing.freshID("https:a.example.com", in: taken), "https:a.example.com#3")
    }

    // MARK: Add (rule 4)

    func testAddRefusesATakenHostOrDeviceAndNeedsAnAddress() {
        let vaults = [DesktopVault(id: "a", name: "Studio", meshNpub: macA, httpsURL: "https://vault.example.com", order: 0)]
        func add(_ typed: String, _ npub: String? = nil, own: String? = nil) -> DesktopVaultsEditing.AddRefusal? {
            if case .failure(let why) = DesktopVaultsEditing.adding(name: "", httpsTyped: typed, meshNpub: npub,
                                                                   kind: .mac, to: vaults, ownNpub: own) { return why }
            return nil
        }
        XCTAssertEqual(add("WSS://Vault.Example.com/"), .hostTaken(vaults[0]))
        XCTAssertEqual(add("", macA), .meshTaken(vaults[0]))
        XCTAssertEqual(add("", macB, own: macB), .ownAddress)
        XCTAssertEqual(add(""), .noAddress)
        XCTAssertEqual(add("", "not-an-npub"), .notMeshAddress)
        XCTAssertNil(add("https://other.example.com", macB))
        XCTAssertEqual(DesktopVaultsEditing.AddRefusal.hostTaken(vaults[0]).message,
                       "That address is already your Vault Studio.")
    }

    // MARK: Change an address

    func testAChangedAddressNeverBringsTheOldSlotBackAsASecondVault() {
        var config = migrated(slot: "https://old.example.com")
        let id = config.desktopVaultsInEffect(ownNpub: nil)[0].id
        XCTAssertNil(config.setDesktopVaultAddress(id: id, to: "https://new.example.com"))
        config.takeInDesktopVaultSlot(ownNpub: nil)
        XCTAssertEqual(config.desktopVaultsInEffect(ownNpub: nil).map(\.httpsURL), ["https://new.example.com"])
        XCTAssertEqual(config.macRelayURLInEffect, "", "the relay leaves the old address")
        XCTAssertEqual(RelayConfiguration.macRelayURL(config: config, mesh: nil), "")
        XCTAssertEqual(DesktopVaultsLogic.envList(config.desktopVaultsInEffect(ownNpub: nil), slot: "",
                                                  typed: config.macRelayURLInEffect), "wss://new.example.com")
    }

    func testClearingTheOnlyAddressIsRefused() {
        var config = migrated(slot: "https://old.example.com")
        let id = config.desktopVaultsInEffect(ownNpub: nil)[0].id
        XCTAssertEqual(config.setDesktopVaultAddress(id: id, to: ""), DesktopVaultsEditing.AddRefusal.noAddress.message)
        XCTAssertEqual(config.desktopVaultsInEffect(ownNpub: nil).count, 1)
    }

    // MARK: Drag

    func testMovingRenumbers() {
        let vaults = (0..<3).map { DesktopVault(id: "v\($0)", name: "", httpsURL: "https://v\($0).example", order: $0) }
        let moved = DesktopVaultsEditing.moving(vaults, from: IndexSet(integer: 2), to: 0)
        XCTAssertEqual(moved.map(\.id), ["v2", "v0", "v1"])
        XCTAssertEqual(moved.map(\.order), [0, 1, 2])
        XCTAssertEqual(DesktopVaultsEditing.moving(vaults, from: IndexSet(integer: 0), to: 3).map(\.id), ["v1", "v2", "v0"])
    }

    // MARK: Rule 8

    func testABareIPAddressIsNeverListed() {
        for ip in ["https://203.0.113.7", "203.0.113.7:4869", "https://[2001:db8::1]:443", "2001:db8::1", "wss://10.0.0.2/relay"] {
            XCTAssertTrue(DesktopVaultsEditing.isIPHost(ip), ip)
        }
        for host in ["https://vault.example.com", "vault.example.com:8443", "https://1.example.com", "https://999.1.1.1"] {
            XCTAssertFalse(DesktopVaultsEditing.isIPHost(host), host)
        }
    }

    // MARK: Rows and a Relays Save (§2.4)

    func testListedEntriesNameTheirVault() {
        let vault = DesktopVault(id: "a", name: "Studio", meshNpub: macA, httpsURL: "https://vault.example.com", order: 0)
        let tags = [["server", "https://blossom.example"], ["server", "https://vault.example.com/"], ["server", "fipsmesh://\(macA)/"]]
        let rows = DesktopVaultsEditing.listedEntries(tags, in: .media, vaults: [vault])
        XCTAssertEqual(rows.map(\.url), ["https://vault.example.com/", "fipsmesh://\(macA)/"])
        XCTAssertEqual(rows.map(\.mesh), [false, true])
        let split = DesktopVaultsEditing.splitting(tags, in: .media, vaults: [vault])
        XCTAssertEqual(split.other, [["server", "https://blossom.example"]])
    }

    func testARelaysSaveKeepsVaultEntriesFirstAndAsPublished() {
        let published = RelayDraft.Published(
            read: ["wss://nostr.land"], write: ["wss://relay.primal.net"], dms: ["wss://inbox.nostr.wine"],
            relayListKnown: true, dmListKnown: true,
            vaultRelays: [["r", "wss://vault.example.com"], ["r", "wss://two.example.com", "write"]],
            vaultInboxes: ["wss://vault.example.com/inbox"])
        let lists = RelayMatrix.Lists(read: ["wss://nostr.land"], write: ["wss://relay.primal.net"],
                                      dms: ["wss://inbox.nostr.wine"], search: [], importing: [])
        let pinned = ["wss://vault.example.com", "wss://two.example.com", "wss://vault.example.com/inbox"]
        var state = RelayDraft.start(lists, published: published, pinned: pinned)
        XCTAssertFalse(RelayDraft.rows(state).contains { pinned.map(RelayMatrix.key).contains($0.entry.key) })
        state = RelayDraft.add(state, url: "wss://new.example", jobs: [.read, .write, .dms])
        let plan = RelayDraft.plan(state, ownRelays: [], ownInbox: "")
        XCTAssertEqual(Array(plan.relayListTags?.prefix(2) ?? []), published.vaultRelays)
        XCTAssertEqual(plan.dmRelays?.first, "wss://vault.example.com/inbox")
        XCTAssertFalse(plan.relayListChanges.contains { $0.url.contains("vault.example.com") })
        XCTAssertFalse(plan.dmChanges.contains { $0.url.contains("vault.example.com") })

        // Another device turned a Vault switch since the page opened: Save stops.
        var fresh = published
        fresh.vaultRelays = [["r", "wss://vault.example.com"]]
        XCTAssertEqual(RelayDraft.saveCheck(opened: published, fresh: fresh, plan: plan), .changed)
        var freshInbox = published
        freshInbox.vaultInboxes = []
        XCTAssertEqual(RelayDraft.saveCheck(opened: published, fresh: freshInbox, plan: plan), .changed)
        XCTAssertEqual(RelayDraft.saveCheck(opened: published, fresh: published, plan: plan), .ok)
    }

    // MARK: My Web names the Vault (plan §6.1)

    func testFoundByNamesTheVaultOnlyWithMoreThanOneDesktop() {
        let a = mac(macA, "Studio"), b = mac(macB, "")
        XCTAssertNil(DesktopVaultPick.foundBy(a, devices: [a]))
        XCTAssertEqual(DesktopVaultPick.foundBy(a, devices: [a, b]), "Found by Studio")
        XCTAssertNil(DesktopVaultPick.foundBy(b, devices: [a, b]))
    }
}
