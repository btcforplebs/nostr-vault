import XCTest
@testable import MediaLogic

/// Never overwrite a user's list (Logen 2026-10-31): a Save edits the newest
/// copy fetched right before it, and "you have no list" needs the relays to
/// agree, not one of them.
final class ListSaveRulesTests: XCTestCase {

    private func lookup(_ event: Int64?, asked: Int, answered: Int) -> ReplaceableLookup<Int64> {
        ReplaceableLookup(event: event, asked: asked, answered: answered)
    }

    private func base(_ l: ReplaceableLookup<Int64>, held: Int64? = nil) -> String {
        switch ListMerge.editBase(l, held: held, createdAt: { $0 }) {
        case .list(let e): return "list \(e)"
        case .none: return "none"
        case .unknown: return "unknown"
        }
    }

    func testOneRelaySayingNoneIsNotNone() {
        XCTAssertEqual(base(lookup(nil, asked: 1, answered: 1)), "unknown", "one relay, one 'none'")
        XCTAssertEqual(base(lookup(nil, asked: 3, answered: 1)), "unknown")
        XCTAssertEqual(base(lookup(nil, asked: 3, answered: 2)), "unknown", "one relay still silent")
        XCTAssertEqual(base(lookup(nil, asked: 0, answered: 0)), "unknown")
        XCTAssertEqual(base(lookup(nil, asked: 2, answered: 2)), "none")
        XCTAssertEqual(base(lookup(nil, asked: 4, answered: 4)), "none")
        XCTAssertFalse(ListMerge.knowsNone(asked: 1, answered: 1))
        XCTAssertTrue(ListMerge.knowsNone(asked: 2, answered: 2))
    }

    func testAFoundListIsTheBaseAndAHeldNewerOneWins() {
        XCTAssertEqual(base(lookup(100, asked: 3, answered: 1)), "list 100")
        XCTAssertEqual(base(lookup(100, asked: 3, answered: 1), held: 200), "list 200", "the one just signed here")
        XCTAssertEqual(base(lookup(nil, asked: 3, answered: 0), held: 200), "unknown", "nobody answered")
    }

    func testAFollowTapGoesOntoTheNewestListKeepingEverythingElse() {
        let launch: [[String]] = [["p", "aa"], ["p", "bb"]]
        // Since launch, another app followed cc, unfollowed bb, and the list has a petname and a non-p tag.
        let newest: [[String]] = [["p", "aa", "wss://r.example", "alice"], ["p", "cc"], ["t", "nostr"]]
        // Follow dd on the launch copy.
        let followed = ListMerge.contactEdit(base: newest, before: launch, after: launch + [["p", "dd"]])
        XCTAssertEqual(followed, newest + [["p", "dd"]], "bb stays gone, cc stays, petname and t tag kept")
        // Unfollow aa on the launch copy.
        let unfollowed = ListMerge.contactEdit(base: newest, before: launch, after: [["p", "bb"]])
        XCTAssertEqual(unfollowed, [["p", "cc"], ["t", "nostr"]])
        // Following someone already on the newest list adds no second entry; case doesn't matter.
        XCTAssertEqual(ListMerge.contactEdit(base: newest, before: launch, after: launch + [["p", "CC"]]), newest)
        // No list anywhere: the tap's follow alone.
        XCTAssertEqual(ListMerge.contactEdit(base: [], before: [], after: [["p", "aa"]]), [["p", "aa"]])
    }

    func testSaveInRelaysRefusesWhenTheListsChangedOrAreUnknown() {
        let opened = RelayDraft.Published(read: ["wss://a.example"], write: ["wss://a.example"], dms: ["wss://d.example"],
                                          relayListKnown: true, dmListKnown: true)
        let both = RelayDraft.Plan(relayListTags: [["r", "wss://b.example"]], relayListChanges: [], dmRelays: ["wss://e.example"],
                                   dmChanges: [], localChanges: [], relayListHeld: false, dmListHeld: false)
        XCTAssertEqual(RelayDraft.saveCheck(opened: opened, fresh: opened, plan: both), .ok)
        var trailing = opened; trailing.read = ["wss://A.example/"]
        XCTAssertEqual(RelayDraft.saveCheck(opened: opened, fresh: trailing, plan: both), .ok, "same relay written differently")
        var moved = opened; moved.write = ["wss://c.example"]
        XCTAssertEqual(RelayDraft.saveCheck(opened: opened, fresh: moved, plan: both), .changed)
        var kept = opened; kept.kept = [["r", "ws://lan.local"]]
        XCTAssertEqual(RelayDraft.saveCheck(opened: opened, fresh: kept, plan: both), .changed)
        var dms = opened; dms.dms = []
        XCTAssertEqual(RelayDraft.saveCheck(opened: opened, fresh: dms, plan: both), .changed)
        var silent = opened; silent.relayListKnown = false
        XCTAssertEqual(RelayDraft.saveCheck(opened: opened, fresh: silent, plan: both), .unknown)
        // Only the DM list is published: a change to the relay list alone doesn't stop it.
        let dmOnly = RelayDraft.Plan(relayListTags: nil, relayListChanges: [], dmRelays: ["wss://e.example"],
                                     dmChanges: [], localChanges: [], relayListHeld: false, dmListHeld: false)
        XCTAssertEqual(RelayDraft.saveCheck(opened: opened, fresh: moved, plan: dmOnly), .ok)
        var dmSilent = opened; dmSilent.dmListKnown = false
        XCTAssertEqual(RelayDraft.saveCheck(opened: opened, fresh: dmSilent, plan: dmOnly), .unknown)
    }
}
