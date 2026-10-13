import XCTest
@testable import MediaLogic

/// A follow / unfollow must never publish when the user's real follow list is
/// unknown. Before this guard a tap queued during a load that then TIMED OUT
/// published a kind 3 holding only the new follow, replacing every follow on
/// every relay (Tron, 2026-10-03).
final class FollowListWipeGuardTests: XCTestCase {
    private let someone = String(repeating: "c", count: 64)
    private let me = String(repeating: "a", count: 64)
    private let other = String(repeating: "d", count: 64)

    /// State after a load that timed out: attempted, not loading, list unknown, nothing in memory.
    func testQueuedFollowAfterTimeoutPublishesNothing() {
        XCTAssertFalse(ContactManager.mayPublishFollowList(hasAttemptedLoad: true, isLoading: false, listConfirmed: false))
        let result = ContactManager.prepareFollow(pubkey: someone, currentPTags: [], currentPubkeys: [],
                                                  hasAttemptedLoad: true, isLoading: false, listConfirmed: false,
                                                  readOnly: false)
        guard case .failure(.listUnavailable) = result else {
            return XCTFail("a follow after a timed-out load must not produce a list to publish, got \(result)")
        }
    }

    func testUnfollowAfterTimeoutPublishesNothing() {
        let result = ContactManager.prepareUnfollow(pubkey: someone, activeAccountHex: me,
                                                    currentPTags: [["p", someone]], currentPubkeys: [someone],
                                                    hasAttemptedLoad: true, isLoading: false, listConfirmed: false,
                                                    readOnly: false)
        guard case .failure(.listUnavailable) = result else {
            return XCTFail("an unfollow after a timed-out load must not produce a list to publish, got \(result)")
        }
    }

    /// A read-only account's Follow / Unfollow is refused before the list
    /// changes, so no "Followed" toast shows next to the read-only one.
    func testReadOnlyFollowLeavesTheListUnchanged() {
        let tags = [["p", someone]]
        let follow = ContactManager.prepareFollow(pubkey: other, currentPTags: tags, currentPubkeys: [someone],
                                                  hasAttemptedLoad: true, isLoading: false, listConfirmed: true,
                                                  readOnly: true)
        guard case .failure(.readOnly) = follow else { return XCTFail("read-only follow must refuse, got \(follow)") }
        let unfollow = ContactManager.prepareUnfollow(pubkey: someone, activeAccountHex: me,
                                                      currentPTags: tags, currentPubkeys: [someone],
                                                      hasAttemptedLoad: true, isLoading: false, listConfirmed: true,
                                                      readOnly: true)
        guard case .failure(.readOnly) = unfollow else { return XCTFail("read-only unfollow must refuse, got \(unfollow)") }
        // Not queued as "once your list loads" either: read-only wins over a list still loading.
        let loading = ContactManager.prepareFollow(pubkey: other, currentPTags: [], currentPubkeys: [],
                                                   hasAttemptedLoad: false, isLoading: true, listConfirmed: false,
                                                   readOnly: true)
        guard case .failure(.readOnly) = loading else { return XCTFail("read-only must not queue, got \(loading)") }
    }

    func testTimeoutDoesNotConfirmTheList() {
        // Two of three relays answered, none had a list: unknown, not "new account".
        XCTAssertFalse(ContactManager.loadConfirmsList(foundList: false, relaysAsked: 3, relaysAnswered: 2))
        XCTAssertFalse(ContactManager.loadConfirmsList(foundList: false, relaysAsked: 0, relaysAnswered: 0))
    }

    func testEveryRelayAnsweringEmptyIsANewAccount() {
        XCTAssertTrue(ContactManager.loadConfirmsList(foundList: false, relaysAsked: 3, relaysAnswered: 3))
        let result = ContactManager.prepareFollow(pubkey: someone, currentPTags: [], currentPubkeys: [],
                                                  hasAttemptedLoad: true, isLoading: false, listConfirmed: true,
                                                  readOnly: false)
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

    /// Every list the publish guard stops must count as refused, so the edit
    /// is rolled back and the user told, not left on screen unpublished.
    func testGuardRefusesEmptyAndShrunkLists() {
        XCTAssertFalse(ContactManager.mayPublish(tagCount: 0, lastFetchedCount: 0), "Empty list")
        XCTAssertFalse(ContactManager.mayPublish(tagCount: 9, lastFetchedCount: 20), "Shrunk past half")
        XCTAssertTrue(ContactManager.mayPublish(tagCount: 2, lastFetchedCount: 3), "One unfollow from a short list")
        XCTAssertTrue(ContactManager.mayPublish(tagCount: 19, lastFetchedCount: 20))
    }

    /// One deliberate Unfollow on a loaded list always publishes, even when
    /// it empties or halves the list. Every other publish keeps the guard.
    func testSingleUnfollowPassesTheGuard() {
        XCTAssertTrue(ContactManager.mayPublish(tagCount: 0, lastFetchedCount: 1, unfollowFrom: 1), "1 → 0")
        XCTAssertTrue(ContactManager.mayPublish(tagCount: 1, lastFetchedCount: 2, unfollowFrom: 2), "2 → 1")
        XCTAssertTrue(ContactManager.mayPublish(tagCount: 11, lastFetchedCount: 30, unfollowFrom: 12), "Half of the fetched count")
        XCTAssertFalse(ContactManager.mayPublish(tagCount: 0, lastFetchedCount: 1), "Not an unfollow")
        XCTAssertFalse(ContactManager.mayPublish(tagCount: 0, lastFetchedCount: 5, unfollowFrom: 5), "More than one removed")
        XCTAssertFalse(ContactManager.mayPublish(tagCount: 9, lastFetchedCount: 20, unfollowFrom: 20), "More than one removed")
    }

    /// A read-only account is told so; only a refusal that can clear says "try again".
    func testReadOnlyAccountIsNotToldToTryAgain() {
        XCTAssertTrue(ContactManager.isReadOnly(signingMode: "local", hasKey: false))
        XCTAssertFalse(ContactManager.isReadOnly(signingMode: "local", hasKey: true))
        XCTAssertFalse(ContactManager.isReadOnly(signingMode: "nip46", hasKey: false), "A bunker signs")
        XCTAssertEqual(ContactManager.publishFailedMessage(follow: true, readOnly: true),
                       "This account is read-only. Add its key to follow.")
        XCTAssertEqual(ContactManager.publishFailedMessage(follow: false, readOnly: true),
                       "This account is read-only. Add its key to unfollow.")
        XCTAssertEqual(ContactManager.publishFailedMessage(follow: false, readOnly: false), "Couldn't unfollow, try again")
    }
}
