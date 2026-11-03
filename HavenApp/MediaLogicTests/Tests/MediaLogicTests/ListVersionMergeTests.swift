import XCTest
@testable import MediaLogic

/// List backups › Merge rules (twin of web `list-version-merge.test.mjs` and
/// Android `ListVersionMergeTest.kt`): entries compare by type and value, the
/// list now is always in, a duplicate keeps the current form, private
/// anywhere stays private, an entry removed in an ordinary edit stays out
/// while one lost to a wipe comes back, empty versions can't be ticked.
final class ListVersionMergeTests: XCTestCase {
    private var serial = 0
    private var asked = 0

    private func p(_ n: Int) -> String { let h = String(n, radix: 16); return String(repeating: "0", count: 64 - h.count) + h }
    private func v(_ kind: Int, _ tags: [[String]], at: Int64, content: String = "") -> ListVersion {
        serial += 1
        return ListVersion(id: String(format: "%064d", serial), pubkey: "me", kind: kind, createdAt: at, tags: tags, content: content)
    }
    /// A fake private part: "enc:" + the JSON the signer would return.
    private func enc(_ tags: [[String]]) -> String {
        "enc:" + String(data: try! JSONSerialization.data(withJSONObject: tags), encoding: .utf8)!
    }
    private func decrypt(_ c: String) async throws -> String {
        asked += 1
        guard c.hasPrefix("enc:") else { throw NSError(domain: "test", code: 1) }
        return String(c.dropFirst(4))
    }
    private func open(_ x: ListVersion, locked: Bool = false) async -> ListVersionMerge.Opened {
        await ListVersionMerge.open(x, decrypt: locked ? nil : { try await self.decrypt($0) })
    }
    private func follows(_ ns: [Int], at: Int64) -> ListVersion { v(3, ns.map { ["p", p($0)] }, at: at, content: #"{"relays":"keep"}"#) }

    func testEntryIdentity() {
        XCTAssertEqual(ListVersionMerge.itemKey(kind: 3, tag: ["p", p(1).uppercased(), "wss://hint"]),
                       ListVersionMerge.itemKey(kind: 3, tag: ["p", p(1), "", "alice"]))
        XCTAssertEqual(ListVersionMerge.itemKey(kind: 10050, tag: ["relay", "wss://Relay.Example:443//a/"]),
                       ListVersionMerge.itemKey(kind: 10050, tag: ["relay", "wss://relay.example/a"]))
        XCTAssertEqual(ListVersionMerge.normURL("WSS://Relay.Example/"), "wss://relay.example")
        XCTAssertEqual(ListVersionMerge.normURL("wss://relay.example:7777/"), "wss://relay.example:7777")
        XCTAssertNil(ListVersionMerge.itemKey(kind: 3, tag: ["d", "x"]))
        XCTAssertNil(ListVersionMerge.itemKey(kind: 3, tag: ["p"]))
        XCTAssertFalse(ListVersionMerge.canMerge(0))
        XCTAssertFalse(ListVersionMerge.canMerge(10002), "only Settings › Relays saves a 10002 (Logen 10-31, kept 11-03)")
        XCTAssertFalse(ListVersionMerge.canMerge(30000))
    }

    func testDeltaLine() {
        XCTAssertEqual(ListVersionMerge.deltaLine(kind: 3, added: 340, removed: 2), "+340 follows, −2")
        XCTAssertEqual(ListVersionMerge.deltaLine(kind: 3, added: 1, removed: 0), "+1 follow")
        XCTAssertEqual(ListVersionMerge.deltaLine(kind: 10000, added: 0, removed: 3), "−3 muted entries")
        XCTAssertEqual(ListVersionMerge.deltaLine(kind: 10003, added: 0, removed: 0), "Same as now")
        XCTAssertEqual(ListVersionMerge.deltaLine(kind: 10050, added: 3, removed: 0), "+3 relays")
        XCTAssertEqual(ListVersionMerge.deltaLine(kind: 10004, added: 2, removed: 0), "+2 communities")
    }

    func testEmptyVersionsAreNeverOffered() async {
        let empty = await open(v(10003, [], at: 1))
        XCTAssertTrue(empty.isEmpty)
        XCTAssertNotNil(ListVersionMerge.pickProblem(empty))
        let locked = await open(v(10003, [], at: 1, content: enc([["e", p(1)]])), locked: true)
        XCTAssertFalse(locked.isEmpty, "an unread private part may hold anything")
        XCTAssertNil(ListVersionMerge.pickProblem(locked))
        let broken = await open(v(10003, [], at: 1, content: "garbage"))
        XCTAssertNotNil(ListVersionMerge.pickProblem(broken))
    }

    func testMergeKeepsCurrentFormAndOrder() async {
        let cur = await open(v(3, [["p", p(1), "wss://now"], ["p", p(2)]], at: 30))
        let old = await open(v(3, [["p", p(1), "wss://old"], ["p", p(3)]], at: 10))
        let d = ListVersionMerge.delta(old, current: cur)
        XCTAssertEqual(d.added, 1); XCTAssertEqual(d.removed, 1)
        let rows = ListVersionMerge.build(current: cur, picked: [old], all: [cur, old])
        XCTAssertEqual(rows.map { $0.tag[1] }, [p(1), p(2), p(3)])
        XCTAssertEqual(rows[0].tag, ["p", p(1), "wss://now"])
        XCTAssertEqual(rows.map(\.status), [.current, .current, .removed])
        XCTAssertTrue(rows[2].ticked, "a short list brings everything back ticked")
        XCTAssertEqual(rows[2].at, 30, "with the date it went, for the Review line")
    }

    func testLaterRemoveVersusWipe() async {
        let ten = Array(1...10)
        let v1 = await open(follows(ten + [11], at: 10))
        let v2 = await open(follows(ten, at: 20)) // removed 11: an edit
        let v3 = await open(follows([1, 2], at: 30)) // a wipe
        let rows = ListVersionMerge.build(current: v3, picked: [v1], all: [v3, v2, v1])
        // 11 went in an edit, but v3 (within the look-ahead) wipes v1 too:
        // the drain rule counts it lost, dated by the wipe (web/Android same).
        let r11 = rows.first { $0.tag[1] == p(11) }!
        XCTAssertEqual(r11.status, .lost); XCTAssertTrue(r11.ticked); XCTAssertEqual(r11.at, 30)
        let r5 = rows.first { $0.tag[1] == p(5) }!
        XCTAssertEqual(r5.status, .lost); XCTAssertTrue(r5.ticked); XCTAssertEqual(r5.at, 30)
        let sum = ListVersionMerge.summary(kind: 3, rows: rows)
        XCTAssertEqual(sum.total, 11); XCTAssertEqual(sum.added, 9); XCTAssertEqual(sum.leftOut, 0); XCTAssertEqual(sum.removed, 0)
        // Kind 3's content is never opened as a private part.
        XCTAssertEqual(asked, 0)
    }

    func testPrivateAnywhereStaysPrivate() async {
        let cur = await open(v(10000, [["p", p(1)]], at: 30, content: enc([["word", "x"]])))
        let old = await open(v(10000, [["t", "nsfw"]], at: 20, content: enc([["p", p(1)], ["p", p(2)]])))
        var rows = ListVersionMerge.build(current: cur, picked: [old], all: [cur, old])
        XCTAssertTrue(rows.first { $0.tag[1] == p(1) }!.isPrivate, "public now, private before: kept private")
        for i in rows.indices { rows[i].ticked = true }
        let out = ListVersionMerge.tags(rows, current: cur)
        XCTAssertEqual(out.tags, [["t", "nsfw"]])
        XCTAssertEqual(Set(out.privateTags.map { $0[1] }), [p(1), p(2), "x"])
        XCTAssertEqual(ListVersionMerge.summary(kind: 10000, rows: rows).remutes,
                       ListVersionMerge.Remutes(people: 1, words: 0, hashtags: 1, threads: 0))
    }

    /// Tron, PR 1570: moved to the private part after the ticked version.
    func testMovedToPrivateLaterComesBackPrivate() async {
        let v1 = await open(v(10000, [["p", p(5)], ["p", p(6)]], at: 10))
        let v2 = await open(v(10000, [["p", p(6)]], at: 20, content: enc([["p", p(5)]])))
        let cur = await open(v(10000, [], at: 30))
        let rows = ListVersionMerge.build(current: cur, picked: [v1], all: [cur, v2, v1])
        let x = rows.first { $0.tag[1] == p(5) }!
        XCTAssertTrue(x.isPrivate); XCTAssertTrue(x.ticked)
        let out = ListVersionMerge.tags(rows, current: cur)
        XCTAssertFalse(out.tags.contains { $0.count > 1 && $0[1] == p(5) })
        XCTAssertFalse(rows.first { $0.tag[1] == p(6) }!.isPrivate)
    }

    /// Tron, PR 1570 r2: an unmute in a newer locked version stays out once
    /// Merge opens it; only versions as new as the oldest ticked one are read.
    func testOpenForMergeKeepsAnUnmuteOut() async {
        let rest = (20..<29).map { ["p", p($0)] }
        let v0 = await open(v(10000, [], at: 5, content: enc([["p", p(8)]])), locked: true)
        let v1 = await open(v(10000, [["p", p(5)]] + rest, at: 10), locked: true)
        let v2 = await open(v(10000, [["p", p(6)]] + rest, at: 20, content: enc([["word", "y"]])), locked: true)
        let cur = await open(v(10000, [["p", p(6)]] + rest, at: 30, content: enc([["word", "y"]])))
        XCTAssertTrue(v2.locked)
        asked = 0
        let unopened = ListVersionMerge.build(current: cur, picked: [v1], all: [cur, v2, v1, v0])
        let u = unopened.first { $0.tag[1] == p(5) }!
        XCTAssertEqual(u.status, .unsure, "without reading v2 it can't be told"); XCTAssertFalse(u.ticked)
        let all = await ListVersionMerge.openForMerge([cur, v2, v1, v0], picked: [v1], decrypt: { try await self.decrypt($0) })
        XCTAssertEqual(asked, 1, "only the locked version newer than the oldest ticked one")
        XCTAssertTrue(all.first { $0.id == v0.id }!.locked)
        let rows = ListVersionMerge.build(current: cur, picked: [v1], all: all)
        let x = rows.first { $0.tag[1] == p(5) }!
        XCTAssertEqual(x.status, .removed); XCTAssertFalse(x.ticked); XCTAssertFalse(x.isPrivate)
    }

    /// Logen 11-03 (as Lazarus): a private entry whose in-between version
    /// can't be opened can't be told, so it stays out.
    func testUnreadNextVersionIsCantTell() async {
        let rest = (20..<29).map { ["p", p($0)] }
        let v1 = await open(v(10000, rest, at: 10, content: enc([["p", p(7)]])))
        let v2 = await open(v(10000, rest + [["p", p(1)]], at: 20, content: "garbage"))
        let cur = await open(v(10000, rest + [["p", p(1)], ["p", p(2)]], at: 30))
        let rows = ListVersionMerge.build(current: cur, picked: [v1], all: [cur, v2, v1])
        let r = rows.first { $0.tag[1] == p(7) }!
        XCTAssertEqual(r.status, .unsure); XCTAssertFalse(r.ticked); XCTAssertTrue(r.isPrivate)
        XCTAssertEqual(ListVersionMerge.summary(kind: 10000, rows: rows).unsure, 1)
    }

    func testTagsKeepListMetadataAndDropUnticked() async {
        let cur = await open(v(10003, [["title", "Mine"], ["e", p(1)]], at: 30))
        let old = await open(v(10003, [["e", p(2)], ["e", p(3)]], at: 10))
        var rows = ListVersionMerge.build(current: cur, picked: [old], all: [cur, old])
        for i in rows.indices { rows[i].ticked = rows[i].tag[1] != p(3) }
        XCTAssertEqual(ListVersionMerge.tags(rows, current: cur).tags, [["title", "Mine"], ["e", p(1)], ["e", p(2)]])
    }

    func testSaveRefusesVersionsFromAnotherAccount() {
        let a = String(repeating: "a", count: 64), b = String(repeating: "b", count: 64)
        XCTAssertTrue(ListVersionMerge.authoredBy(a, authors: [a]))
        XCTAssertFalse(ListVersionMerge.authoredBy(b, authors: [a]), "A's ticked versions signed as B")
        XCTAssertFalse(ListVersionMerge.authoredBy(a, authors: [a, b]))
        XCTAssertFalse(ListVersionMerge.authoredBy(a, authors: []))
        XCTAssertFalse(ListVersionMerge.authoredBy("", authors: [""]))
    }

    // MARK: Hal's fixtures (Lazarus 0.7 review, Logen "fill the gaps" 2026-11-03)

    /// Swap clobber: a stale copy of the same size replaces the list. By size
    /// nothing shrank; by which entries went it's a wipe.
    func testHalSwapClobber() async {
        let old = await open(follows(Array(1...20), at: 10))
        let stale = await open(follows(Array(101...120), at: 20))
        let rows = ListVersionMerge.build(current: stale, picked: [old], all: [stale, old])
        let back = rows.filter { $0.status != .current }
        XCTAssertEqual(back.count, 20)
        XCTAssertTrue(back.allSatisfy { $0.status == .lost && $0.ticked }, "same size, all different: a clobber")
    }

    /// Bulk deliberate cleanup: 5 of 20 unfollowed stays out; 11 of 20 is
    /// past half and counts as a wipe (the confirm and Review protect that).
    func testHalBulkCleanup() async {
        let v1 = await open(follows(Array(1...20), at: 10))
        let tidy = await open(follows(Array(6...20), at: 20))
        var rows = ListVersionMerge.build(current: tidy, picked: [v1], all: [tidy, v1])
        XCTAssertTrue(rows.filter { $0.status != .current }.allSatisfy { $0.status == .removed && !$0.ticked })
        let big = await open(follows(Array(12...20), at: 20))
        rows = ListVersionMerge.build(current: big, picked: [v1], all: [big, v1])
        XCTAssertTrue(rows.filter { $0.status != .current }.allSatisfy { $0.status == .lost && $0.ticked })
    }

    /// Small list: 3 relays down to 1, and a 4-entry bookmark list edited to
    /// 3, both bring everything back ticked, still dated by the version that
    /// dropped them (Review: "You removed this <date>", Tron 11-03).
    func testHalSmallList() async {
        let r3 = await open(v(10050, [["relay", "wss://a"], ["relay", "wss://b"], ["relay", "wss://c"]], at: 10))
        let r1 = await open(v(10050, [["relay", "wss://a"]], at: 20))
        var rows = ListVersionMerge.build(current: r1, picked: [r3], all: [r1, r3])
        XCTAssertEqual(rows.filter { $0.status == .removed && $0.ticked && $0.at == 20 }.count, 2)
        let b4 = await open(v(10003, (1...4).map { ["e", p($0)] }, at: 10))
        let b3 = await open(v(10003, (1...3).map { ["e", p($0)] }, at: 20))
        rows = ListVersionMerge.build(current: b3, picked: [b4], all: [b3, b4])
        let x = rows.first { $0.tag[1] == p(4) }!
        XCTAssertEqual(x.status, .removed); XCTAssertTrue(x.ticked); XCTAssertEqual(x.at, 20)
        XCTAssertEqual(ListVersionMerge.summary(kind: 10003, rows: rows).leftOut, 0, "ticked, so not counted as left out")
    }

    /// Gap: past the vault's newest 20 it may have let versions go, so a step
    /// that isn't a wipe can't be told; a wipe still counts (the vault keeps
    /// a wipe with the version just before it). A current found only on
    /// relays is a gap too.
    func testHalGapBetweenVersions() async {
        let ten = Array(1...12)
        let old = await open(follows(ten + [50], at: 1))    // pinned, older than the newest 20
        var recent: [ListVersionMerge.Opened] = []
        for i in 0..<20 { recent.append(await open(follows(ten, at: Int64(100 + i)))) }
        let all = recent + [old]
        var rows = ListVersionMerge.build(current: recent.last, picked: [old], all: all)
        var x = rows.first { $0.tag[1] == p(50) }!
        XCTAssertEqual(x.status, .unsure); XCTAssertFalse(x.ticked)
        // Inside the window the same step is an edit.
        let near = Array(recent.suffix(19)) + [old]
        rows = ListVersionMerge.build(current: recent.last, picked: [old], all: near)
        x = rows.first { $0.tag[1] == p(50) }!
        XCTAssertEqual(x.status, .removed)
        // A wipe across the gap is still a wipe.
        let wipe = await open(follows([1], at: 99))
        rows = ListVersionMerge.build(current: recent.last, picked: [old], all: recent + [wipe, old])
        XCTAssertEqual(rows.first { $0.tag[1] == p(50) }!.status, .lost)
        // A current the vault doesn't hold: the step to it can't be told.
        let v1 = await open(follows(ten + [60], at: 10))
        let relayOnly = await open(follows(ten, at: 20))
        rows = ListVersionMerge.build(current: relayOnly, picked: [v1], all: [relayOnly, v1], vault: [v1.id])
        XCTAssertEqual(rows.first { $0.tag[1] == p(60) }!.status, .unsure)
    }

    /// 10002: the current version's read/write marker wins; an old relay
    /// comes back ticked with its own marker.
    func testHal10002Marker() async {
        let old = await open(v(10002, [["r", "wss://a/", "read"], ["r", "wss://b"]], at: 10))
        let cur = await open(v(10002, [["r", "wss://A", "write"]], at: 20))
        let rows = ListVersionMerge.build(current: cur, picked: [old], all: [cur, old])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].tag, ["r", "wss://A", "write"], "current marker kept, not widened")
        XCTAssertEqual(rows[1].tag, ["r", "wss://b"]); XCTAssertTrue(rows[1].ticked)
    }

    /// Unpicked in-between version: the step is judged against it even when
    /// only the oldest and the list now are involved.
    func testHalUnpickedInBetween() async {
        let base = Array(1...12)
        let v1 = await open(follows(base + [70], at: 10))
        let v2 = await open(follows(base, at: 20))          // 70 removed in an edit, not picked
        let v3 = await open(follows(base + [71], at: 30))
        let rows = ListVersionMerge.build(current: v3, picked: [v1], all: [v3, v2, v1])
        let x = rows.first { $0.tag[1] == p(70) }!
        XCTAssertEqual(x.status, .removed); XCTAssertEqual(x.at, 20)
    }

    /// Re-read changes current mid-merge: building again on the new current
    /// judges afresh (the save refuses a stale base; NostrService+ListMerge).
    func testHalReReadChangesCurrent() async {
        let base = Array(1...12)
        let v1 = await open(follows(base + [80, 81], at: 10))
        let cur = await open(follows(base, at: 20))
        var rows = ListVersionMerge.build(current: cur, picked: [v1], all: [cur, v1])
        XCTAssertEqual(rows.filter { $0.status == .removed }.count, 2)
        let newer = await open(follows(base + [80], at: 30)) // another app added 80 back
        rows = ListVersionMerge.build(current: newer, picked: [v1], all: [newer, cur, v1])
        XCTAssertEqual(rows.first { $0.tag[1] == p(80) }!.status, .current)
        XCTAssertEqual(rows.first { $0.tag[1] == p(81) }!.status, .removed)
    }

    /// Ours: a list drained in steps of half is a wipe, as the vault sees it.
    func testSteppedDrain() async {
        let v40 = await open(follows(Array(1...40), at: 10))
        let v20 = await open(follows(Array(1...20), at: 20))
        let v10 = await open(follows(Array(1...10), at: 30))
        let v5 = await open(follows(Array(1...5), at: 40))
        let rows = ListVersionMerge.build(current: v5, picked: [v40], all: [v5, v10, v20, v40])
        XCTAssertEqual(rows.first { $0.tag[1] == p(15) }!.status, .lost, "20 -> 10 is a wipe against 40")
        XCTAssertEqual(rows.first { $0.tag[1] == p(8) }!.status, .lost, "10 -> 5 is a wipe against 20")
        XCTAssertEqual(rows.first { $0.tag[1] == p(30) }!.status, .lost, "dropped at 40 -> 20, then drained: lost (look-ahead)")
    }

    /// A slow tidy, one unfollow per version, is never a drain: within the
    /// look-ahead the list keeps more than half.
    func testSlowTidyIsNotADrain() async {
        var vs: [ListVersionMerge.Opened] = []
        for i in 0..<11 { vs.append(await open(follows(Array((1 + i)...20), at: Int64(10 + i)))) }
        let all = Array(vs.reversed())
        let rows = ListVersionMerge.build(current: all[0], picked: [vs[0]], all: all)
        XCTAssertEqual(rows.first { $0.tag[1] == p(1) }!.status, .removed)
        XCTAssertEqual(rows.first { $0.tag[1] == p(10) }!.status, .removed)
    }

    func testMuteLineCountsEveryKind() {
        func row(_ tag: [String]) -> ListVersionMerge.Row { ListVersionMerge.Row(key: tag.joined(), tag: tag, isPrivate: false) }
        let rows = [row(["p", p(1)]), row(["p", p(2)]), row(["word", "x"]), row(["t", "nsfw"]), row(["e", p(3)])]
        let m = ListVersionMerge.summary(kind: 10000, rows: rows).remutes
        XCTAssertEqual(m.line, "2 people, 1 word, 1 hashtag, 1 thread")
        XCTAssertTrue(ListVersionMerge.summary(kind: 10003, rows: rows).remutes.isEmpty)
    }
}
