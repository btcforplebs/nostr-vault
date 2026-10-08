import XCTest
@testable import MediaLogic

/// What setup publishes for a key it just generated, and the cleanup of the
/// starter-pack picks the old setup step saved as accounts instead of follows.
final class NewAccountSetupTests: XCTestCase {

    private let ownerHex = String(repeating: "ab", count: 32)
    // jack and Vitor: correct in the old file and the new one.
    private let jackNpub = "npub1sg6plzptd64u62a878hep2kev88swjh3tw00gjsfl8f237lmu63q0uf63m"
    private let jackHex = "82341f882b6eabcd2ba7f1ef90aad961cf074af15b9ef44a09f9d2a8fbfbe6a2"
    private let vitorNpub = "npub1gcxzte5zlkncx26j68ez60fzkvtkm9e0vrwdcvsjakxf9mu9qewqlfnj5z"
    private let vitorHex = "460c25e682fda7832b52d1f22d3d22b3176d972f60dcdc3212ed8c92ef85065c"

    // MARK: First contact list

    func testFirstContactListIsOwnerThenPicksInOrder() {
        let tags = ContactManager.newAccountContactTags(ownerHex: ownerHex, pickedNpubs: [vitorNpub, jackNpub])
        XCTAssertEqual(tags, [["p", ownerHex], ["p", vitorHex], ["p", jackHex]])
    }

    func testFirstContactListDropsDuplicatesAndBadNpubs() {
        let badChecksum = "npub1s33sw46p7vpsmak6v8j4x2naxqvqgv5xpep0lmllz9lxm7qds8gs8r5n32"
        let tags = ContactManager.newAccountContactTags(
            ownerHex: ownerHex,
            pickedNpubs: [jackNpub, badChecksum, jackNpub.uppercased(), jackNpub]
        )
        XCTAssertEqual(tags, [["p", ownerHex], ["p", jackHex]])
    }

    func testNoPicksIsOwnerOnly() {
        // FeedService publishes nothing for this: owner-only means nobody picked.
        XCTAssertEqual(ContactManager.newAccountContactTags(ownerHex: ownerHex, pickedNpubs: []), [["p", ownerHex]])
    }

    // MARK: Account cleanup

    func testStarterPicksWithoutAKeyAreRemoved() {
        let real = "npub1realaccountnotinanystarterpack"
        let kept = ContactManager.accountsWithoutStarterPackPicks([jackNpub, real, vitorNpub]) { _ in false }
        XCTAssertEqual(kept, [real])
    }

    func testStarterPickWithAKeyIsKept() {
        // Someone who added jack as an account with jack's key meant to.
        let kept = ContactManager.accountsWithoutStarterPackPicks([jackNpub, vitorNpub]) { $0 == self.jackNpub }
        XCTAssertEqual(kept, [jackNpub])
    }

    func testCleanupMatchesStoredEntriesWithStrayWhitespace() {
        let kept = ContactManager.accountsWithoutStarterPackPicks([" \(jackNpub)\n"]) { _ in false }
        XCTAssertEqual(kept, [])
    }

    func testCleanupListIsTheOldShippedFileNotTheCurrentOne() {
        // "fiatjaf" as shipped was really PABLOF7z. The old npub must be in the
        // cleanup list; fiatjaf's real npub must not, or a user who later added
        // the real fiatjaf as an account would lose him.
        XCTAssertTrue(ContactManager.starterNpubsSetupAddedAsAccounts.contains(
            "npub1l2vyh47mk2p0qlsku7hg0vn29faehy9hy34ygaclpn66ukqp3afqutajft"))
        XCTAssertFalse(ContactManager.starterNpubsSetupAddedAsAccounts.contains(
            "npub180cvv07tjdrrgpa0j7j7tmnyl2yr6yr7l8j4s3evf6u64th6gkwsyjh6w6"))
        XCTAssertEqual(ContactManager.starterNpubsSetupAddedAsAccounts.count, 15)
    }

    // MARK: Relay list

    func testRelayListAdvertisesPublicRelaysOnly() {
        let tags = RelayConfiguration.newAccountRelayListTags(broadcastRelays: [
            "wss://relay.primal.net",
            "ws://127.0.0.1:4869",
            "wss://localhost:4869",
            "wss://nos.lol",
            "wss://relay.primal.net",
            "https://not-a-relay.example",
            " wss://nostr.mom ",
        ])
        XCTAssertEqual(tags, [["r", "wss://relay.primal.net"], ["r", "wss://nos.lol"], ["r", "wss://nostr.mom"]])
    }

    // MARK: The shipped starter packs

    func testEveryShippedStarterNpubIsValid() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("HavenApp/Resources/starter_packs.json")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let packs = try XCTUnwrap(json?["packs"] as? [[String: Any]])
        var count = 0
        for pack in packs {
            for account in (pack["accounts"] as? [[String: Any]]) ?? [] {
                count += 1
                let npub = account["npub"] as? String ?? ""
                XCTAssertNotNil(NpubValidation.hexPubkey(fromNpub: npub), "\(account["name"] ?? "?"): \(npub)")
            }
        }
        XCTAssertGreaterThan(count, 0)
    }
}
