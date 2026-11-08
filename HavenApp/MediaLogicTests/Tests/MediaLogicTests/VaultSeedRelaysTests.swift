import XCTest
@testable import MediaLogic

/// The vault reads only the owner's own relay list (Logen 2026-11-08).
final class VaultSeedRelaysTests: XCTestCase {
    private let read = ["wss://relay.primal.net", "wss://my.relay/"]
    private let write = ["wss://my.relay", "wss://relay.snort.social"]

    func testVaultSeedsAreReadThenWriteThenPicksDeduplicated() {
        XCTAssertEqual(VaultSeedRelays.vaultSeeds(read: read, write: write, chosen: ["wss://picked.example", "WSS://RELAY.PRIMAL.NET"]),
                       ["wss://relay.primal.net", "wss://my.relay/", "wss://relay.snort.social", "wss://picked.example"])
    }

    /// The point: nothing the owner didn't list. damus is not in their list,
    /// so the vault never asks it.
    func testNoHiddenSeedRelays() {
        let seeds = VaultSeedRelays.vaultSeeds(read: read, write: write, chosen: [])
        XCTAssertFalse(seeds.contains { $0.contains("damus") || $0.contains("wellorder") || $0.contains("ditto") })
    }

    /// A saved list of the old shipped defaults was never the owner's pick.
    func testOldDefaultsAreDroppedOnLoad() {
        let oldIOS = ["wss://relay.primal.net", "wss://relay.damus.io", "wss://relay.btcforplebs.com", "wss://nostr-pub.wellorder.net"]
        XCTAssertEqual(VaultSeedRelays.chosenImportRelays(oldIOS, own: read + write, mac: ""), [])
        let oldAndroid = ["wss://relay.primal.net", "wss://relay.btcforplebs.com", "wss://nostr-pub.wellorder.net"]
        XCTAssertEqual(VaultSeedRelays.chosenImportRelays(oldAndroid, own: [], mac: ""), [])
    }

    /// What the owner added stays; their own relays and the Mac relay (the
    /// vault reads those anyway) are not kept as picks.
    func testOwnersPicksSurvive() {
        let file = ["wss://relay.primal.net", "wss://mac.local:4869", "wss://picked.example", "wss://relay.damus.io"]
        XCTAssertEqual(VaultSeedRelays.chosenImportRelays(file, own: read + write, mac: "wss://mac.local:4869"),
                       ["wss://picked.example", "wss://relay.damus.io"])
    }

    /// A new account's vault reads its own starter list and nothing else:
    /// no import seed defaults on top.
    func testNewConfigReadsOnlyItsOwnList() {
        let config = HavenConfig()
        XCTAssertEqual(config.importSeedRelays, [])
        XCTAssertEqual(Set(config.vaultSeedRelays), Set(config.feedRelays + config.blastrRelays))
        var mine = HavenConfig()
        mine.feedRelays = ["wss://only.mine"]
        mine.blastrRelays = ["wss://only.mine/"]
        XCTAssertEqual(mine.vaultSeedRelays, ["wss://only.mine"])
    }
}
