import XCTest
@testable import MediaLogic

/// NV_NEW_USER_SCAN_HASHTAG_2026_11_26: joining by scan publishes the follow
/// list at setup end. That used to clear the one "brand-new key" mark for
/// every list, so the first hashtag (10015) save needed every relay to
/// answer, and one down relay (damus 503) flipped the chip back.
final class FreshAccountKeysTests: XCTestCase {
    private func defaults() throws -> UserDefaults {
        let suite = "FreshAccountKeysTests.\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { d.removePersistentDomain(forName: suite) }
        return d
    }

    func testTheFollowListPublishLeavesTheInterestListPass() throws {
        let d = try defaults()
        FreshAccountKeys.mark("abc", kinds: FreshAccountKeys.newAccountKinds, defaults: d)
        XCTAssertTrue(FreshAccountKeys.isFresh("abc", kind: 3, defaults: d))
        XCTAssertTrue(FreshAccountKeys.isFresh("abc", kind: 10015, defaults: d))

        FreshAccountKeys.clear("abc", kind: 3, defaults: d) // scan-join's kind 3
        XCTAssertFalse(FreshAccountKeys.isFresh("abc", kind: 3, defaults: d))
        XCTAssertTrue(FreshAccountKeys.isFresh("abc", kind: 10015, defaults: d), "the first hashtag save keeps its pass")

        FreshAccountKeys.clear("abc", kind: 10015, defaults: d)
        XCTAssertFalse(FreshAccountKeys.isFresh("abc", kind: 10015, defaults: d))
    }

    func testKeysAndKindsDontMix() throws {
        let d = try defaults()
        FreshAccountKeys.mark("abc", kinds: [3, 10015], defaults: d)
        XCTAssertFalse(FreshAccountKeys.isFresh("def", kind: 10015, defaults: d))
        XCTAssertFalse(FreshAccountKeys.isFresh("abc", kind: 10002, defaults: d))
        XCTAssertFalse(FreshAccountKeys.isFresh("", kind: 3, defaults: d))
        FreshAccountKeys.clear("def", kind: 3, defaults: d)
        XCTAssertTrue(FreshAccountKeys.isFresh("abc", kind: 3, defaults: d))
    }

    func testAKeyMarkedBeforeKindsWereKeptStaysFreshForItsFollowList() throws {
        let d = try defaults()
        d.set(["abc"], forKey: "freshAccountKeys")
        XCTAssertTrue(FreshAccountKeys.isFresh("abc", kind: 3, defaults: d))
    }

    /// The scan-join state: kind 3 cleared, 10015 still fresh, one own relay
    /// (damus) never answered. The save builds on an empty list.
    func testScanJoinHashtagSaveGoesThroughWithOneRelayDown() throws {
        let d = try defaults()
        FreshAccountKeys.mark("abc", kinds: FreshAccountKeys.newAccountKinds, defaults: d)
        FreshAccountKeys.clear("abc", kind: 3, defaults: d)
        let own = ["wss://relay.primal.net", "wss://relay.damus.io", "wss://relay.snort.social", "wss://relay.btcforplebs.com"]
        let lookup = ReplaceableLookup<InterestList>(
            event: nil, asked: 4, answered: 3,
            answeredBy: ["wss://relay.primal.net", "wss://relay.snort.social", "wss://relay.btcforplebs.com"])
        guard case .unknown = InterestList.saveBase(lookup, held: nil, own: own, fresh: false) else {
            return XCTFail("without the pass a silent relay blocks the save")
        }
        guard case .none = InterestList.saveBase(lookup, held: nil, own: own,
                                                 fresh: FreshAccountKeys.isFresh("abc", kind: 10015, defaults: d)) else {
            return XCTFail("the scan-join's first hashtag save was refused")
        }
    }

    /// NV_331_SHIP_CHECK_TRON_2026_11_26 §2: a held new account's first
    /// follow is signed, then refused by every relay, then the app relaunches
    /// (the signed copy is held in memory only). One own relay stays silent.
    /// The pass must still be there, or that account can't follow anyone and
    /// can't reach the 5 it needs.
    func testARefusedFirstFollowKeepsThePassAcrossARelaunch() throws {
        let d = try defaults()
        FreshAccountKeys.mark("abc", kinds: FreshAccountKeys.newAccountKinds, defaults: d)
        for kind in FreshAccountKeys.newAccountKinds {
            FreshAccountKeys.settle("abc", kind: kind, accepted: false, defaults: d)
            XCTAssertTrue(FreshAccountKeys.isFresh("abc", kind: kind, defaults: d), "kind \(kind) refused everywhere is still nowhere")
        }

        let own = ["wss://relay.primal.net", "wss://relay.damus.io"]
        let lookup = ReplaceableLookup<Int64>(event: nil, asked: 3, answered: 2,
                                              answeredBy: ["wss://relay.primal.net", "wss://nos.lol"])
        let base = ListMerge.editBase(lookup, held: nil, own: own, createdAt: { $0 })
        guard case .unknown = base else { return XCTFail("one silent own relay leaves the list unknown") }
        guard case .none = ListMerge.freshKeyBase(base, fresh: FreshAccountKeys.isFresh("abc", kind: 3, defaults: d),
                                                  lookup: lookup, held: nil, createdAt: { $0 }) else {
            return XCTFail("the next follow after a relaunch was refused")
        }

        FreshAccountKeys.settle("abc", kind: 3, accepted: true, defaults: d)
        XCTAssertFalse(FreshAccountKeys.isFresh("abc", kind: 3, defaults: d), "a relay took it: the key has a follow list")
        XCTAssertTrue(FreshAccountKeys.isFresh("abc", kind: 10015, defaults: d))
        FreshAccountKeys.settle("abc", kind: 10015, accepted: true, defaults: d)
        XCTAssertFalse(FreshAccountKeys.isFresh("abc", kind: 10015, defaults: d))
    }
}
