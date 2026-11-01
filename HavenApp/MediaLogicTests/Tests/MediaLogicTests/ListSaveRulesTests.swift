import XCTest
@testable import MediaLogic

/// Never overwrite a user's list (Logen 2026-10-31): a Save edits the newest
/// copy fetched right before it, and "you have no list" needs the relays to
/// agree, not one of them.
final class ListSaveRulesTests: XCTestCase {

    /// `asked` relays, all of them the account's own; the first `answered` answered and sent `event`.
    private func lookup(_ event: Int64?, asked: Int, answered: Int) -> ReplaceableLookup<Int64> {
        let heard = Set((0..<answered).map { "wss://own\($0).example" })
        return ReplaceableLookup(event: event, asked: asked, answered: answered, answeredBy: heard, from: event == nil ? [] : heard)
    }

    private func base(_ l: ReplaceableLookup<Int64>, held: Int64? = nil) -> String {
        switch ListMerge.editBase(l, held: held, own: (0..<l.asked).map { "wss://own\($0).example" }, createdAt: { $0 }) {
        case .list(let e): return "list \(e)"
        case .none: return "none"
        case .unknown: return "unknown"
        case .noRelayList: return "noRelayList"
        }
    }

    func testOneRelaySayingNoneIsNotNone() {
        XCTAssertEqual(base(lookup(nil, asked: 1, answered: 1)), "unknown", "one relay, one 'none'")
        XCTAssertEqual(base(lookup(nil, asked: 3, answered: 1)), "unknown")
        XCTAssertEqual(base(lookup(nil, asked: 3, answered: 2)), "unknown", "one relay still silent")
        XCTAssertEqual(base(lookup(nil, asked: 0, answered: 0)), "noRelayList", "no own relays at all")
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

    /// Every edit in the app names the account's write relays as `own`, so a
    /// copy from purplepag.es or a read relay alone never becomes the base
    /// (Tron #1459: kind 3, 10063 and publishMergedList passed none).
    func testEveryEditBaseCallSiteNamesTheOwnRelays() throws {
        let app = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("HavenApp")
        var sites: [String] = []
        let walk = try XCTUnwrap(FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil))
        for case let url as URL in walk where url.pathExtension == "swift" && url.lastPathComponent != "ListMerge.swift" {
            let src = try String(contentsOf: url, encoding: .utf8)
            var rest = src[...]
            while let call = rest.range(of: "ListMerge.editBase(") {
                let tail = rest[call.upperBound...]
                let end = try XCTUnwrap(tail.range(of: "createdAt:")).lowerBound
                let args = tail[..<end]
                sites.append(url.lastPathComponent)
                XCTAssertTrue(args.contains("own: Self.ownListRelays(for: ") || args.contains("own: NostrService.ownListRelays(for: "),
                              "\(url.lastPathComponent): editBase without the own relays: \(args)")
                rest = tail[end...]
            }
        }
        XCTAssertEqual(sites.sorted(), ["FeedService+Follow.swift", "NostrService+ListPublishing.swift",
                                        "NostrService+ListPublishing.swift", "NostrService+ListPublishing.swift"])
    }


    // MARK: - No relay list of the account's own (Tron #1456/#1459 follow-up)

    /// With no kind 10002 known, the app's default relays are not the
    /// account's: their "none" must not let an edit start from nothing.
    func testNoRelayListOfItsOwnIsNotKnown() {
        let defaultsAllNone = ReplaceableLookup<Int64>(event: nil, asked: 5, answered: 5,
                                                       answeredBy: Set((0..<5).map { "wss://default\($0).example" }))
        guard case .noRelayList = ListMerge.editBase(defaultsAllNone, held: nil, own: [], createdAt: { $0 }) else {
            return XCTFail("five default relays saying none is not 'you have none'")
        }
        let defaultsSentOne = ReplaceableLookup(event: 100 as Int64, asked: 5, answered: 5,
                                                answeredBy: ["wss://default0.example"], from: ["wss://default0.example"])
        guard case .noRelayList = ListMerge.editBase(defaultsSentOne, held: 200, own: [], createdAt: { $0 }) else {
            return XCTFail("a copy from a default relay is not checked against the account's own")
        }
        XCTAssertTrue(ListMerge.noRelayListMessage.contains("Nothing was changed"))
    }

    /// The own relays come from the account's kind 10002 only: none known,
    /// none at all (never the defaults), loopback and repeats dropped.
    func testOwnRelaysAreOnlyTheOnesInTheAccountsRelayList() {
        let loopback: (String) -> Bool = { $0.contains("127.0.0.1") || $0.contains("localhost") }
        XCTAssertEqual(ListMerge.ownRelays(published: nil, isLoopback: loopback), [])
        XCTAssertEqual(ListMerge.ownRelays(published: [], isLoopback: loopback), [])
        XCTAssertEqual(ListMerge.ownRelays(published: ["wss://a.example", "ws://127.0.0.1:3355", "wss://A.example/", "wss://b.example"],
                                           isLoopback: loopback), ["wss://a.example", "wss://b.example"])
    }

    func testFollowMessageSaysThereIsNoRelayList() {
        XCTAssertTrue(ContactManager.publishFailedMessage(follow: true, readOnly: false, noRelayList: true).contains("no relay list"))
        XCTAssertEqual(ContactManager.publishFailedMessage(follow: true, readOnly: false), "Couldn't follow, try again")
        XCTAssertTrue(ContactManager.publishFailedMessage(follow: false, readOnly: true, noRelayList: true).contains("read-only"))
    }

    // MARK: - Copies dated far ahead (MAX_SKEW, as the web's follows.js)

    func testACopyDatedTooFarAheadIsNotTheBase() {
        let now: Int64 = 1_000_000
        let own = ["wss://own0.example", "wss://own1.example"]
        let ahead = now + ListMerge.maxSkew
        // The relays' copy is 15 min ahead: skipped, and the held copy is the base.
        let future = ReplaceableLookup(event: ahead, asked: 2, answered: 2, answeredBy: Set(own), from: ["wss://own0.example"])
        guard case .list(let base) = ListMerge.editBase(future, held: now - 10, own: own, now: now, createdAt: { $0 }) else {
            return XCTFail("most own relays answered; the held copy is usable")
        }
        XCTAssertEqual(base, now - 10)
        // Just under the limit still counts.
        let near = ReplaceableLookup(event: ahead - 1, asked: 2, answered: 2, answeredBy: Set(own), from: ["wss://own0.example"])
        guard case .list(let nearBase) = ListMerge.editBase(near, held: nil, own: own, now: now, createdAt: { $0 }) else { return XCTFail("near copy") }
        XCTAssertEqual(nearBase, ahead - 1)
        // Only a far-ahead copy: a list exists, so never "none".
        guard case .unknown = ListMerge.editBase(future, held: nil, own: own, now: now, createdAt: { $0 }) else {
            return XCTFail("a skipped copy means a list exists")
        }
        // The lookup skipped one itself (ahead), every own relay answered: still not "none".
        var skipped = ReplaceableLookup<Int64>(event: nil, asked: 2, answered: 2, answeredBy: Set(own))
        skipped.ahead = true
        guard case .unknown = ListMerge.editBase(skipped, held: nil, own: own, now: now, createdAt: { $0 }) else {
            return XCTFail("the lookup saw a list dated ahead")
        }
        XCTAssertFalse(skipped.confirmedNone)
        // A held copy far ahead is skipped too.
        let quiet = ReplaceableLookup<Int64>(event: nil, asked: 2, answered: 2, answeredBy: Set(own))
        guard case .unknown = ListMerge.editBase(quiet, held: ahead + 60, own: own, now: now, createdAt: { $0 }) else {
            return XCTFail("a held copy dated ahead is not the base, nor 'none'")
        }
    }

    func testAnEditIsDatedAfterItsBase() {
        XCTAssertEqual(ListMerge.signedAt(now: 1000, base: 500), 1000)
        XCTAssertEqual(ListMerge.signedAt(now: 1000, base: 1000), 1001)
        XCTAssertEqual(ListMerge.signedAt(now: 1000, base: 1600), 1601, "a base ahead of this clock: one second after it")
        XCTAssertEqual(ListMerge.signedAt(now: 1000, base: nil), 1000)
    }
}
