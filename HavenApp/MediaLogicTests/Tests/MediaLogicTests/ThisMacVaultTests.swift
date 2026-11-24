import XCTest
@testable import MediaLogic

/// This Mac as a Vault on its own lists (Desktop Vaults P8): Public on the
/// web and "Media over the Mesh" change only its entries, after the other
/// Vaults (§2.5 rules 1-3).
final class ThisMacVaultTests: XCTestCase {
    private let own = "npub1" + String(repeating: "m", count: 58)
    private let other = "npub1" + String(repeating: "q", count: 58)

    private func config(_ relayURL: String) -> HavenConfig {
        var c = HavenConfig()
        c.relayURL = relayURL
        c.macRelayURL = ""
        c.desktopVaults = []
        c.meshDevices = []
        return c
    }

    func testOnlyAReachableDomainIsItsWebAddress() {
        XCTAssertEqual(config("vault.example.com").thisMacVault(meshNpub: own, name: "Studio").httpsURL, "https://vault.example.com")
        XCTAssertNil(config("").thisMacVault(meshNpub: own, name: "Studio").httpsURL, "mesh only")
        XCTAssertNil(config("localhost:3355").thisMacVault(meshNpub: own, name: "Studio").httpsURL)
        XCTAssertNil(config("192.168.1.20:3355").thisMacVault(meshNpub: own, name: "Studio").httpsURL)
        XCTAssertEqual(config("").thisMacVault(meshNpub: own, name: "Studio").meshNpub, own)
    }

    func testItGoesAfterTheOtherVaultsAndCountsOnce() {
        var c = config("vault.example.com")
        let laptop = DesktopVault(id: "laptop", name: "Laptop", meshNpub: other, httpsURL: "https://laptop.example.com", order: 0)
        // A Vault at this Mac's own domain (an old slot entry): this Mac, not another Vault.
        let twin = DesktopVault(id: "twin", name: "Twin", httpsURL: "https://Vault.example.com", order: 1)
        c.desktopVaults = [laptop, twin]
        let mac = c.thisMacVault(meshNpub: own, name: "Studio")
        let vaults = c.vaultsWithThisMac(mac)
        XCTAssertEqual(vaults.map(\.id), ["laptop", HavenConfig.thisMacVaultID], "the Vault that is this Mac counts once")

        let tags = [["server", "https://laptop.example.com"], ["server", "https://blossom.band"]]
        XCTAssertEqual(DesktopVaultsLists.switching(true, mac, path: .web, in: .media, tags: tags, vaults: vaults),
                       .tags([["server", "https://laptop.example.com"], ["server", "https://vault.example.com"], ["server", "https://blossom.band"]]),
                       "after the other Vault, before the owner's own")
        XCTAssertEqual(DesktopVaultsLists.switching(true, mac, path: .mesh, in: .media, tags: tags, vaults: vaults),
                       .tags(tags + [["server", "fipsmesh://\(own)/"]]), "mesh entries go last")
    }

    func testTwoMacsBothPublicStayListed() {
        let c = config("vault.example.com")
        let mac = c.thisMacVault(meshNpub: own, name: "Studio")
        let tags = [["r", "wss://laptop.example.com"], ["r", "wss://vault.example.com"], ["r", "wss://relay.damus.io"]]
        // Turning this Mac off takes only its own entry out; the other Mac stays.
        XCTAssertEqual(DesktopVaultsLists.switching(false, mac, path: .web, in: .relays, tags: tags, vaults: c.vaultsWithThisMac(mac)),
                       .tags([["r", "wss://laptop.example.com"], ["r", "wss://relay.damus.io"]]))
        XCTAssertTrue(DesktopVaultsLists.isListed(mac, path: .web, in: .relays, tags: tags))
    }
}
