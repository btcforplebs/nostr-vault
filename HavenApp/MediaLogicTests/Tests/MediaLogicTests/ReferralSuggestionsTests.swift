import XCTest
@testable import MediaLogic

/// Setup's referrer step: which of the referrer's follows are offered, the
/// batch follow that takes them, and the stash that carries them through setup.
final class ReferralSuggestionsTests: XCTestCase {
    private func k(_ n: Int) -> String { String(format: "%064x", n) }

    func testFollowsFromAContactList() {
        let tags = [["p", k(1)], ["e", k(9)], ["p", k(2).uppercased()], ["p", k(1)], ["p", "short"], ["p"]]
        XCTAssertEqual(ReferralSuggestions.follows(inContactListTags: tags), [k(1), k(2)])
    }

    func testMostFollowedAmongTheReferrersFollowsComeFirst() {
        let follows = [k(1), k(2), k(3), k(4)]
        let lists = [
            k(1): [k(3), k(4)],
            k(2): [k(3), k(4), k(4)],      // a repeat counts once
            k(3): [k(4), k(3)],            // following yourself doesn't count
            k(99): [k(1), k(1), k(1)],     // not one of the referrer's follows: ignored
        ]
        // k4: 3 (from k1, k2, k3); k3: 2; k1 and k2: 0, in list order.
        XCTAssertEqual(ReferralSuggestions.rank(referrerFollows: follows, lists: lists, exclude: []), [k(4), k(3), k(1), k(2)])
    }

    func testExcludedNeverOfferedAndCappedAtTen() {
        let follows = (1...30).map(k)
        let ranked = ReferralSuggestions.rank(referrerFollows: follows, lists: [:], exclude: [k(1), k(3)])
        XCTAssertEqual(ranked.count, 10)
        XCTAssertEqual(ranked.first, k(2))
        XCTAssertFalse(ranked.contains(k(1)) || ranked.contains(k(3)))
    }

    func testBatchFollowAddsOnlyNewPeopleInOneEdit() {
        let result = ContactManager.prepareFollowMany(
            pubkeys: [k(2), k(3), k(3), k(4)], currentPTags: [["p", k(1)], ["p", k(2)]], currentPubkeys: [k(1), k(2)],
            hasAttemptedLoad: true, isLoading: false, listConfirmed: true, readOnly: false)
        guard case .success(let r) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(r.added, [k(3), k(4)])
        XCTAssertEqual(r.pubkeys, [k(1), k(2), k(3), k(4)])
        XCTAssertEqual(r.pTags, [["p", k(1)], ["p", k(2)], ["p", k(3)], ["p", k(4)]])
    }

    func testBatchFollowRefusesWhatSingleFollowRefuses() {
        func run(_ attempted: Bool, _ loading: Bool, _ confirmed: Bool, _ readOnly: Bool, _ keys: [String] = ["x"]) -> ContactManager.FollowActionError? {
            if case .failure(let e) = ContactManager.prepareFollowMany(pubkeys: keys, currentPTags: [], currentPubkeys: [],
                hasAttemptedLoad: attempted, isLoading: loading, listConfirmed: confirmed, readOnly: readOnly) { return e }
            return nil
        }
        XCTAssertEqual(run(true, false, true, true), .readOnly)
        XCTAssertEqual(run(false, false, true, false), .contactsNotLoaded)
        XCTAssertEqual(run(true, true, true, false), .contactsNotLoaded)
        XCTAssertEqual(run(true, false, false, false), .listUnavailable)
        XCTAssertEqual(run(true, false, true, false, []), .alreadyFollowing)
    }

    func testStashCarriesTheReferrerAndFollowsThroughSetupOnce() {
        let defaults = UserDefaults(suiteName: "ReferralSuggestionsTests-\(UUID().uuidString)")!
        let stash = SetupReferral(defaults: defaults)
        stash.pendingReferrer = k(7).uppercased()
        XCTAssertEqual(stash.pendingReferrer, k(7))
        stash.pendingReferrer = "not a key"
        XCTAssertNil(stash.pendingReferrer)
        stash.pendingReferrer = k(7)
        stash.pendingFollows = [k(7), k(8), k(7), "junk"]
        XCTAssertEqual(SetupReferral(defaults: defaults).pendingFollows, [k(7), k(8)], "survives a relaunch")
        XCTAssertEqual(stash.takeFollows(), [k(7), k(8)])
        XCTAssertEqual(stash.takeFollows(), [])
        XCTAssertNil(stash.pendingReferrer)
    }
}
