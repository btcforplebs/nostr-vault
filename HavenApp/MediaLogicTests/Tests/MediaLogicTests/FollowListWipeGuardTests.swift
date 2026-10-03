import XCTest
@testable import MediaLogic

/// A follow / unfollow must never publish when the user's real follow list is
/// unknown. Before this guard a tap queued during a load that then TIMED OUT
/// published a kind 3 holding only the new follow, replacing every follow on
/// every relay (Tron, 2026-10-03).
final class FollowListWipeGuardTests: XCTestCase {
    private let someone = String(repeating: "c", count: 64)
    private let me = String(repeating: "a", count: 64)

    /// State after a load that timed out: attempted, not loading, list unknown, nothing in memory.
    func testQueuedFollowAfterTimeoutPublishesNothing() {
        XCTAssertFalse(ContactManager.mayPublishFollowList(hasAttemptedLoad: true, isLoading: false, listConfirmed: false))
        let result = ContactManager.prepareFollow(pubkey: someone, currentPTags: [], currentPubkeys: [],
                                                  hasAttemptedLoad: true, isLoading: false, listConfirmed: false)
        guard case .failure(.listUnavailable) = result else {
            return XCTFail("a follow after a timed-out load must not produce a list to publish, got \(result)")
        }
    }

    func testUnfollowAfterTimeoutPublishesNothing() {
        let result = ContactManager.prepareUnfollow(pubkey: someone, activeAccountHex: me,
                                                    currentPTags: [["p", someone]], currentPubkeys: [someone],
                                                    hasAttemptedLoad: true, isLoading: false, listConfirmed: false)
        guard case .failure(.listUnavailable) = result else {
            return XCTFail("an unfollow after a timed-out load must not produce a list to publish, got \(result)")
        }
    }

    func testTimeoutDoesNotConfirmTheList() {
        // Two of three relays answered, none had a list: unknown, not "new account".
        XCTAssertFalse(ContactManager.loadConfirmsList(foundList: false, relaysAsked: 3, relaysAnswered: 2))
        XCTAssertFalse(ContactManager.loadConfirmsList(foundList: false, relaysAsked: 0, relaysAnswered: 0))
    }

    func testEveryRelayAnsweringEmptyIsANewAccount() {
        XCTAssertTrue(ContactManager.loadConfirmsList(foundList: false, relaysAsked: 3, relaysAnswered: 3))
        let result = ContactManager.prepareFollow(pubkey: someone, currentPTags: [], currentPubkeys: [],
                                                  hasAttemptedLoad: true, isLoading: false, listConfirmed: true)
        guard case .success(let list) = result else { return XCTFail("new account should be able to follow, got \(result)") }
        XCTAssertEqual(list.pubkeys, [someone])
    }

    func testFoundListConfirms() {
        XCTAssertTrue(ContactManager.loadConfirmsList(foundList: true, relaysAsked: 3, relaysAnswered: 1))
    }
}

/// Tron: counting EOSE messages instead of relays let one relay repeating
/// EOSE stand in for the relay that holds the list.
final class FollowListEOSETallyTests: XCTestCase {
    func testDuplicateEOSEFromOneRelayDoesNotConfirm() {
        var tally = ContactManager.EOSETally()
        tally.sent(subId: "cl-a", to: "wss://one")
        tally.sent(subId: "cl-b", to: "wss://two")
        tally.eose(from: "wss://one", subId: "cl-a")
        tally.eose(from: "wss://one", subId: "cl-a")
        XCTAssertEqual(tally.answered.count, 1)
        XCTAssertFalse(ContactManager.loadConfirmsList(foundList: false, relaysAsked: 2, relaysAnswered: tally.answered.count))
    }

    func testEOSEForAnotherSubscriptionIsIgnored() {
        var tally = ContactManager.EOSETally()
        tally.sent(subId: "cl-a", to: "wss://one")
        tally.eose(from: "wss://one", subId: "something-else")
        XCTAssertTrue(tally.answered.isEmpty)
    }

    func testBothRelaysAnsweringConfirmsANewAccount() {
        var tally = ContactManager.EOSETally()
        tally.sent(subId: "cl-a", to: "wss://one")
        tally.sent(subId: "cl-b", to: "wss://two")
        tally.eose(from: "wss://one", subId: "cl-a")
        tally.eose(from: "wss://two", subId: "cl-b")
        XCTAssertTrue(ContactManager.loadConfirmsList(foundList: false, relaysAsked: 2, relaysAnswered: tally.answered.count))
    }
}
