import XCTest
@testable import MediaLogic

/// The parsed list is what the next Follow/Unfollow publishes, so it must be
/// the relay's list and nothing else. It used to add the account itself and
/// every other account on the device, and an unfollow then published them.
final class ContactListParseTests: XCTestCase {
    private let me = String(repeating: "a", count: 64)
    private let other = String(repeating: "b", count: 64)
    private let friend = String(repeating: "c", count: 64)
    private let gone = String(repeating: "d", count: 64)

    func testKeepsTheRelayListExactly() {
        let tags = [["p", friend, "wss://r.example", "pet"], ["p", gone]]
        let parsed = ContactManager.parseContactList(pTags: tags)
        XCTAssertEqual(parsed.pTags, tags)
        XCTAssertEqual(parsed.pubkeys, [friend, gone])
        XCTAssertEqual(parsed.relayPTagCount, 2)
    }

    func testUnfollowPublishesNeitherSelfNorAnotherAccount() {
        let parsed = ContactManager.parseContactList(pTags: [["p", friend], ["p", gone]])
        let result = ContactManager.prepareUnfollow(
            pubkey: gone, activeAccountHex: me,
            currentPTags: parsed.pTags, currentPubkeys: parsed.pubkeys,
            hasAttemptedLoad: true, isLoading: false, listConfirmed: true, readOnly: false
        )
        guard case .success(let next) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(next.pubkeys, [friend])
        XCTAssertFalse(next.pubkeys.contains(me))
        XCTAssertFalse(next.pubkeys.contains(other))
    }
}
