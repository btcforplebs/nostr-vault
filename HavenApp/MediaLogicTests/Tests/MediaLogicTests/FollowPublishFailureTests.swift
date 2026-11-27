import XCTest
@testable import MediaLogic

/// The banner says why a follow was put back, not just "try again" (rd,
/// 2026-11-27: 4 of 7 own relays answered, so the lookup was `.unknown`).
final class FollowPublishFailureTests: XCTestCase {
    private let own = ["wss://nos.lol", "wss://relay.damus.io", "wss://relay.primal.net", "wss://nostr.wine",
                       "wss://rd.feeds.relay.tools", "wss://relay.snort.social", "wss://blaastr.com"]

    func testUnknownCountsOwnRelaysThatAnswered() {
        // Answers come back with a trailing slash and in other case, plus an
        // indexer that isn't one of the account's own relays.
        let answeredBy: Set<String> = ["wss://relay.primal.net/", "WSS://nostr.wine", "wss://nos.lol/", "wss://purplepag.es"]
        let reason = FollowPublishFailure.relaysDidNotAnswer(answeredBy: answeredBy, own: own)
        XCTAssertEqual(reason, .relaysDidNotAnswer(ownAnswered: 3, own: 7))
        XCTAssertEqual(reason.message(follow: true),
                       "Couldn't follow: only 3 of your 7 relays answered, so your newest follow list can't be checked. Nothing changed. Remove dead relays in Settings › Relays, then try again.")
    }

    func testUnknownWithEveryOwnRelayAnsweredDoesNotBlameDeadRelays() {
        let message = FollowPublishFailure.relaysDidNotAnswer(ownAnswered: 1, own: 1).message(follow: false)
        XCTAssertEqual(message, "Couldn't unfollow: not enough relays answered, so your newest follow list can't be checked. Nothing changed. Try again in a moment.")
    }

    func testEveryExitHasItsOwnText() {
        let reasons: [FollowPublishFailure] = [.wouldShrink, .readOnly, .noBefore, .accountSwitched, .noRelayList,
                                               .relaysDidNotAnswer(ownAnswered: 3, own: 7), .tooFewAnswered(answered: 0), .tooFewAnswered(answered: 1),
                                               .notSigned, .wrongSigner, .refused]
        let follow = reasons.map { $0.message(follow: true) }
        XCTAssertEqual(Set(follow).count, reasons.count)
        XCTAssertFalse(follow.contains("Couldn't follow, try again"))
        XCTAssertTrue(FollowPublishFailure.notSigned.message(follow: true).contains("your signer didn't sign it"))
        XCTAssertTrue(FollowPublishFailure.refused.message(follow: true).contains("every relay refused it"))
        for message in reasons.map({ $0.message(follow: false) }) {
            XCTAssertTrue(message.contains("unfollow"), message)
        }
    }

    func testReadOnlyAndNoRelayListKeepTheirWording() {
        XCTAssertEqual(FollowPublishFailure.readOnly.message(follow: true),
                       ContactManager.publishFailedMessage(follow: true, readOnly: true))
        XCTAssertEqual(FollowPublishFailure.noRelayList.message(follow: false),
                       "Couldn't unfollow. " + ListMerge.noRelayListMessage)
    }
}
