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

    private func keys(_ picks: [ReferralSuggestions.Pick]) -> [String] { picks.map(\.pubkey) }

    func testWithNoMutualsMostFollowedAmongTheReferrersFollowsComeFirst() {
        let follows = [k(1), k(2), k(3), k(4)]
        let lists = [
            k(1): [k(3), k(4)],
            k(2): [k(3), k(4), k(4)],      // a repeat counts once
            k(3): [k(4), k(3)],            // following yourself doesn't count
            k(99): [k(1), k(1), k(1)],     // not one of the referrer's follows: ignored
        ]
        // Nobody follows the referrer (k50) back: k4: 3; k3: 2; k1 and k2: 0, in list order.
        let ranked = ReferralSuggestions.rank(referrer: k(50), referrerFollows: follows, lists: lists, exclude: [])
        XCTAssertEqual(keys(ranked), [k(4), k(3), k(1), k(2)])
        XCTAssertEqual(ranked.map(\.close), [0, 0, 0, 0])
    }

    func testTheReferrersCloseCircleOutranksFame() {
        let me = k(50)
        // k1, k2 follow the referrer back (close). k3..k6 don't.
        let follows = (1...8).map(k)
        let lists = [
            k(1): [me, k(7)],
            k(2): [me, k(7), k(1)],
            k(3): [k(8)], k(4): [k(8)], k(5): [k(8)], k(6): [k(8)], // k8 is famous: 4 follows, none close
        ]
        XCTAssertEqual(ReferralSuggestions.closeCircle(referrer: me, referrerFollows: follows, lists: lists), [k(1), k(2)])
        let ranked = ReferralSuggestions.rank(referrer: me, referrerFollows: follows, lists: lists, exclude: [])
        // k7: 2 close; k1: 1 close (from k2); then k8 by its 4 overall; then list order.
        XCTAssertEqual(Array(keys(ranked).prefix(3)), [k(7), k(1), k(8)])
        XCTAssertEqual(ranked.first?.close, 2)
        XCTAssertEqual(ranked.first { $0.pubkey == k(8) }?.close, 0)
    }

    func testTopicsAreSharedHashtagsOfThePeopleOffered() {
        let notes: [(author: String, tags: [[String]])] = [
            (k(1), [["t", "Photography"], ["t", "bitcoin"]]),
            (k(1), [["t", "photography"]]),           // one person counts once
            (k(2), [["t", "#photography"], ["t", "2026"]]),
            (k(3), [["t", "bitcoin"], ["t", "x"]]),    // too short
            (k(4), [["t", "bitcoin"]]),
            (k(9), [["t", "garden"], ["t", "garden"]]), // not offered
            (k(2), [["t", "garden"]]),                   // one person only
        ]
        let topics = ReferralSuggestions.topics(notes: notes, among: [k(1), k(2), k(3), k(4)])
        XCTAssertEqual(topics.map(\.topic), ["bitcoin", "photography"])
        XCTAssertEqual(topics.first?.people, [k(1), k(3), k(4)])
    }

    func testExcludedNeverOfferedAndCappedAtThePool() {
        let follows = (1...50).map(k)
        let ranked = ReferralSuggestions.rank(referrer: k(99), referrerFollows: follows, lists: [:], exclude: [k(1), k(3)])
        XCTAssertEqual(ranked.count, ReferralSuggestions.pool)
        XCTAssertEqual(ranked.first?.pubkey, k(2))
        XCTAssertFalse(keys(ranked).contains(k(1)) || keys(ranked).contains(k(3)))
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
