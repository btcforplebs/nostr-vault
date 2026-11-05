import XCTest
@testable import MediaLogic

/// A removed account's blocks used to stay in `blockedNpubsPerAccount`, which
/// the relay's device-wide blacklist merges, so they kept blocking everyone.
final class AccountRemovalEntriesTests: XCTestCase {
    private func config() -> HavenConfig {
        var c = HavenConfig()
        c.ownerNpub = "npub1owner"
        c.whitelistedNpubs = ["npub1b", "npub1c"]
        for npub in ["npub1owner", "npub1b", "npub1c"] {
            c.blockedNpubsPerAccount[npub] = ["npub1blockedby_\(npub)"]
            c.blockedNpubsLastSyncTimestamp[npub] = 100
            c.publishRelayListPerAccount[npub] = true
            c.notificationPrefsPerAccount[npub] = NotificationPreferences()
            c.accountSigningModes[npub] = "local"
            c.accountCredentials[npub] = "ncryptsec1x"
        }
        return c
    }

    func testRemovingAnAccountDropsItsBlocksFromTheRelayBlacklist() {
        var c = config()
        c.removeAccountEntries(npub: " npub1b\n")
        XCTAssertFalse(c.allBlockedNpubsAcrossAccounts.contains("npub1blockedby_npub1b"))
        XCTAssertEqual(Set(c.allBlockedNpubsAcrossAccounts), ["npub1blockedby_npub1owner", "npub1blockedby_npub1c"])
    }

    func testRemovingAnAccountDropsEveryPerAccountEntry() {
        var c = config()
        c.removeAccountEntries(npub: "npub1b")
        XCTAssertEqual(c.whitelistedNpubs, ["npub1c"])
        XCTAssertNil(c.blockedNpubsPerAccount["npub1b"])
        XCTAssertNil(c.blockedNpubsLastSyncTimestamp["npub1b"])
        XCTAssertNil(c.publishRelayListPerAccount["npub1b"])
        XCTAssertNil(c.notificationPrefsPerAccount["npub1b"])
        XCTAssertNil(c.accountSigningModes["npub1b"])
        XCTAssertNil(c.accountCredentials["npub1b"])
        XCTAssertNotNil(c.blockedNpubsPerAccount["npub1c"])
    }

    func testTheOwnerIsNeverRemoved() {
        var c = config()
        c.removeAccountEntries(npub: "npub1owner")
        XCTAssertEqual(c.blockedNpubsPerAccount["npub1owner"], ["npub1blockedby_npub1owner"])
    }
}
