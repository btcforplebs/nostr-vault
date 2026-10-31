import XCTest
@testable import MediaLogic

/// Settings > Relays as a draft: Yours vs App defaults, fixed row order, and
/// what Save publishes. Ported from Android `relay/RelayDraftTest.kt`.
final class RelayDraftTests: XCTestCase {
    typealias Job = RelayMatrix.Job
    typealias Section = RelayDraft.Section

    // This device: the app's defaults, as Vyram's phone had them.
    private let config = RelayMatrix.Lists(
        read: ["wss://relay.damus.io", "wss://relay.primal.net", "wss://relay.snort.social"],
        write: ["wss://relay.btcforplebs.com", "wss://relay.damus.io"],
        dms: ["wss://relay.btcforplebs.com", "wss://relay.primal.net"],
        search: ["wss://search.nos.today"],
        importing: ["wss://relay.btcforplebs.com", "wss://nostr-pub.wellorder.net"]
    )

    // His published kind 10002 and 10050.
    private let published = RelayDraft.Published(
        read: ["wss://nostr.land", "wss://relay.primal.net"],
        write: ["wss://relay.primal.net"],
        dms: ["wss://inbox.nostr.wine"],
        relayListKnown: true,
        dmListKnown: true
    )

    private let ownRelay = "wss://vault.example"
    private let ownInbox = "wss://vault.example/inbox"

    private func start() -> RelayDraft.State {
        RelayDraft.start(config, published: published, pinned: [ownRelay, ownInbox])
    }
    private func key(_ url: String) -> String { RelayMatrix.key(url) }
    private func order(_ s: RelayDraft.State) -> [String] { RelayDraft.rows(s).map(\.entry.key) }
    private func section(_ s: RelayDraft.State, _ url: String) -> Section? {
        s.layout.first { $0.key == key(url) }?.section
    }
    private func plan(_ s: RelayDraft.State, inbox: String? = nil) -> RelayDraft.Plan {
        RelayDraft.plan(s, ownRelays: [ownRelay], ownInbox: inbox ?? ownInbox)
    }

    func testHisPublishedRelaysAreYoursAndEverythingElseIsAnAppDefault() {
        let s = start()
        XCTAssertEqual(section(s, "wss://nostr.land"), .yours)
        XCTAssertEqual(section(s, "wss://relay.primal.net"), .yours)
        XCTAssertEqual(section(s, "wss://inbox.nostr.wine"), .yours)
        XCTAssertEqual(section(s, "wss://relay.damus.io"), .defaults)
        XCTAssertEqual(section(s, "wss://nostr-pub.wellorder.net"), .defaults)
        // Yours rows come first.
        XCTAssertEqual(s.layout.prefix(3).map(\.section), [.yours, .yours, .yours])
        // His relays are in their jobs even though this device never had them.
        XCTAssertEqual(RelayDraft.jobs(s.draft, key("wss://nostr.land")), [.read])
        XCTAssertEqual(RelayDraft.jobs(s.draft, key("wss://inbox.nostr.wine")), [.dms])
        XCTAssertEqual(RelayDraft.changeCount(s), 0)
    }

    func testTheVaultsOwnRelayAndInboxGetNoRow() {
        var withOwn = published
        withOwn.read = published.read + [ownRelay]
        withOwn.dms = published.dms + [ownInbox]
        let s = RelayDraft.start(config, published: withOwn, pinned: [ownRelay, ownInbox])
        XCTAssertFalse(s.layout.contains { $0.key == key(ownRelay) || $0.key == key(ownInbox) })
        XCTAssertFalse(s.draft.read.contains { key($0) == key(ownRelay) })
    }

    func testImportIsAJobLikeTheOthersAndEveryRowCanBeRemoved() {
        var s = start()
        let wellorder = key("wss://nostr-pub.wellorder.net")
        XCTAssertEqual(Set<Job>([.read, .importing]).intersection(RelayDraft.jobs(s.draft, wellorder)), [.importing])
        s = RelayDraft.toggle(s, key: wellorder, job: .importing)
        XCTAssertTrue(RelayDraft.jobs(s.draft, wellorder).isEmpty)
        s = RelayDraft.remove(start(), key: wellorder)
        XCTAssertFalse(s.draft.importing.contains { key($0) == wellorder })
        XCTAssertEqual(RelayDraft.rows(s).first { $0.entry.key == wellorder }?.removed, true)
    }

    func testTappingDotsAndRemovingNeverMovesARow() {
        let s0 = start()
        let before = order(s0)
        var s = s0
        for row in RelayDraft.rows(s0) {
            for job in Job.allCases { s = RelayDraft.toggle(s, key: row.entry.key, job: job) }
        }
        XCTAssertEqual(order(s), before)
        // A row with every dot off stays where it was.
        let damus = key("wss://relay.damus.io")
        var off = s0
        for job in Job.allCases where RelayDraft.jobs(off.draft, damus).contains(job) {
            off = RelayDraft.toggle(off, key: damus, job: job)
        }
        XCTAssertTrue(RelayDraft.jobs(off.draft, damus).isEmpty)
        XCTAssertEqual(order(off), before)
        s = RelayDraft.remove(s0, key: damus)
        XCTAssertEqual(order(s), before)
        s = RelayDraft.undo(s, key: damus)
        XCTAssertEqual(order(s), before)
        XCTAssertEqual(RelayDraft.jobs(s.draft, damus), RelayDraft.jobs(s0.draft, damus))
    }

    func testSaveKeepsTheOrderAndOnlyRemovedRowsLeave() {
        let s0 = start()
        let damus = key("wss://relay.damus.io")
        var s = RelayDraft.toggle(s0, key: key("wss://relay.snort.social"), job: .write)
        s = RelayDraft.remove(s, key: damus)
        let saved = RelayDraft.saved(s, plan: plan(s))
        XCTAssertEqual(order(saved), order(s0).filter { $0 != damus })
        XCTAssertEqual(saved.layout.map(\.section), s0.layout.filter { $0.key != damus }.map(\.section))
        XCTAssertEqual(RelayDraft.changeCount(saved), 0)
    }

    func testAnAddedRelayGoesAtTheEndOfYours() {
        let s = RelayDraft.add(start(), url: "wss://" + "relay.new.example", jobs: [.read, .write])
        let last = s.layout.last
        XCTAssertEqual(last?.key, key("wss://relay.new.example"))
        XCTAssertEqual(last?.section, .yours)
        XCTAssertEqual(RelayDraft.changeCount(s), 1)
    }

    func testNothingIsPublishedWhenNothingChanged() {
        let p = plan(start())
        XCTAssertNil(p.relayListTags)
        XCTAssertNil(p.dmRelays)
        XCTAssertTrue(p.localChanges.isEmpty)
    }

    func testChangingAppDefaultsNeverPublishes() {
        var s = start()
        s = RelayDraft.remove(s, key: key("wss://relay.damus.io"))
        s = RelayDraft.toggle(s, key: key("wss://relay.snort.social"), job: .write)
        s = RelayDraft.toggle(s, key: key("wss://relay.btcforplebs.com"), job: .dms)
        let p = plan(s)
        XCTAssertNil(p.relayListTags)
        XCTAssertNil(p.dmRelays)
        XCTAssertEqual(p.localChanges.count, 3)
        XCTAssertEqual(p.localChanges.first { key($0.url) == key("wss://relay.damus.io") }?.removed, [.read, .write])
    }

    func testAYoursEditPublishesOnlyYoursNeverTheDefaults() throws {
        let s = RelayDraft.toggle(start(), key: key("wss://nostr.land"), job: .write)
        let p = plan(s)
        let tags = try XCTUnwrap(p.relayListTags)
        let urls = Set(tags.map { key($0[1]) })
        XCTAssertEqual(urls, [key(ownRelay), key("wss://nostr.land"), key("wss://relay.primal.net")])
        XCTAssertFalse(urls.contains(key("wss://relay.damus.io")))
        // nostr.land is now Read and Write: no marker.
        XCTAssertEqual(tags.first { key($0[1]) == key("wss://nostr.land") }, ["r", "wss://nostr.land"])
        XCTAssertNil(p.dmRelays)
        XCTAssertTrue(p.relayListChanges.contains { key($0.url) == key("wss://nostr.land") && $0.added == [.write] })
    }

    func testRemovingHisDMRelayPublishesA10050WithoutItAndAnEmptiedOneGoesOutEmpty() {
        var s = RelayDraft.add(start(), url: "wss://dm2.example", jobs: [.dms])
        s = RelayDraft.remove(s, key: key("wss://inbox.nostr.wine"))
        XCTAssertEqual(plan(s, inbox: "").dmRelays, ["wss://dm2.example"])
        // Default DM relays (btcforplebs, primal-as-default-DM) are not added.
        let emptied = plan(RelayDraft.remove(start(), key: key("wss://inbox.nostr.wine")), inbox: "")
        XCTAssertEqual(emptied.dmRelays, [])
    }

    func testTheVaultInboxLeadsAPublishedDMList() {
        let s = RelayDraft.add(start(), url: "wss://dm2.example", jobs: [.dms])
        XCTAssertEqual(plan(s).dmRelays, [ownInbox, "wss://inbox.nostr.wine", "wss://dm2.example"])
    }

    func testAnUnknownPublishedListIsNeverPublishedOver() {
        var unknown = published
        unknown.relayListKnown = false
        unknown.dmListKnown = false
        var s = RelayDraft.start(config, published: unknown)
        s = RelayDraft.toggle(s, key: key("wss://nostr.land"), job: .write)
        s = RelayDraft.remove(s, key: key("wss://inbox.nostr.wine"))
        let p = plan(s)
        XCTAssertNil(p.relayListTags)
        XCTAssertNil(p.dmRelays)
        XCTAssertTrue(p.relayListHeld)
        XCTAssertTrue(p.dmListHeld)
    }

    func testAddingAnAppDefaultByHandMakesItYoursAndPublishesIt() throws {
        let s = RelayDraft.add(start(), url: "wss://relay.snort.social", jobs: [.read, .write])
        XCTAssertEqual(section(s, "wss://relay.snort.social"), .yours)
        XCTAssertEqual(s.layout.last?.key, key("wss://relay.snort.social"))
        let tags = try XCTUnwrap(plan(s).relayListTags)
        XCTAssertTrue(tags.contains { key($0[1]) == key("wss://relay.snort.social") })
    }

    func testSearchAndImportOnAYoursRowStayOnThisDevice() {
        var s = RelayDraft.toggle(start(), key: key("wss://nostr.land"), job: .search)
        s = RelayDraft.toggle(s, key: key("wss://nostr.land"), job: .importing)
        let p = plan(s)
        XCTAssertNil(p.relayListTags)
        XCTAssertEqual(p.localChanges.count, 1)
        XCTAssertEqual(p.localChanges.first?.added, [.search, .importing])
    }

    func testARemovedRowIgnoresTapsUntilUndo() {
        let k = key("wss://nostr.land")
        let removed = RelayDraft.remove(start(), key: k)
        XCTAssertEqual(RelayDraft.toggle(removed, key: k, job: .write), removed)
    }

    func testResetSearchAddsNewDefaultRowsAtTheEndWithoutMovingAny() {
        let s0 = start()
        let s = RelayDraft.resetSearch(s0, defaults: ["wss://search.nos.today", "wss://relay.vertexlab.io"])
        XCTAssertEqual(Array(order(s).prefix(order(s0).count)), order(s0))
        XCTAssertEqual(s.layout.last,
                       RelayDraft.Entry(key: key("wss://relay.vertexlab.io"), url: "wss://relay.vertexlab.io", section: .defaults))
    }

    private let defaultsAnswered: Set<String> = [
        "wss://relay.btcforplebs.com", "wss://relay.damus.io", "wss://relay.snort.social", "wss://relay.primal.net",
    ]

    func testAListFoundAnywhereIsSettled() {
        XCTAssertTrue(RelayDraft.settled(found: true, answeredBy: ["wss://relay.primal.net"]))
    }

    func testIndexersSilentAndOnlyDefaultsAnsweringLeavesTheListHeld() {
        // A 10002 made in another app lives on the indexers and the owner's relays;
        // our defaults answering empty says nothing about it.
        XCTAssertFalse(RelayDraft.settled(found: false, answeredBy: defaultsAnswered))
        XCTAssertFalse(RelayDraft.settled(found: false, answeredBy: defaultsAnswered.union(["wss://purplepag.es"])))
        XCTAssertFalse(RelayDraft.settled(found: false, answeredBy: []))
    }

    func testBothIndexersAnsweringWithoutItSettlesAnEmptyList() {
        XCTAssertTrue(RelayDraft.settled(found: false, answeredBy: ["wss://purplepag.es/", "wss://User.KindPag.es"]))
    }

    func testAHeldListFromThatLookupNeverPublishesOverTheRealOne() {
        let held = RelayDraft.Published(
            relayListKnown: RelayDraft.settled(found: false, answeredBy: defaultsAnswered),
            dmListKnown: RelayDraft.settled(found: false, answeredBy: defaultsAnswered)
        )
        var s = RelayDraft.add(RelayDraft.start(config, published: held), url: "wss://mine.example",
                               jobs: [.read, .write, .dms])
        s = RelayDraft.remove(s, key: key("wss://relay.damus.io"))
        let p = plan(s)
        XCTAssertNil(p.relayListTags)
        XCTAssertNil(p.dmRelays)
        XCTAssertTrue(p.relayListHeld && p.dmListHeld)
    }
}
