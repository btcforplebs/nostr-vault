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
        XCTAssertFalse(ListVersionMerge.canMerge(10002))
        XCTAssertFalse(ListVersionMerge.canMerge(30000))
    }

    func testDeltaLine() {
        XCTAssertEqual(ListVersionMerge.deltaLine(kind: 3, added: 340, removed: 2), "+340 follows, −2")
        XCTAssertEqual(ListVersionMerge.deltaLine(kind: 3, added: 1, removed: 0), "+1 follow")
        XCTAssertEqual(ListVersionMerge.deltaLine(kind: 10000, added: 0, removed: 3), "−3 muted entries")
        XCTAssertEqual(ListVersionMerge.deltaLine(kind: 10003, added: 0, removed: 0), "Same as now")
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
        XCTAssertEqual(rows.map(\.status), [.current, .current, .removed], "the next version took p(3) out in an edit")
    }

    func testLaterRemoveVersusWipe() async {
        let ten = Array(1...10)
        let v1 = await open(follows(ten + [11], at: 10))
        let v2 = await open(follows(ten, at: 20)) // removed 11: an edit
        let v3 = await open(follows([1, 2], at: 30)) // a wipe
        let rows = ListVersionMerge.build(current: v3, picked: [v1], all: [v3, v2, v1])
        let r11 = rows.first { $0.tag[1] == p(11) }!
        XCTAssertEqual(r11.status, .removed); XCTAssertFalse(r11.ticked); XCTAssertEqual(r11.at, 20)
        let r5 = rows.first { $0.tag[1] == p(5) }!
        XCTAssertEqual(r5.status, .lost); XCTAssertTrue(r5.ticked); XCTAssertEqual(r5.at, 30)
        let sum = ListVersionMerge.summary(kind: 3, rows: rows)
        XCTAssertEqual(sum.total, 10); XCTAssertEqual(sum.added, 8); XCTAssertEqual(sum.leftOut, 1); XCTAssertEqual(sum.removed, 0)
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
        XCTAssertEqual(ListVersionMerge.summary(kind: 10000, rows: rows).remutes, 1)
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
        let v0 = await open(v(10000, [], at: 5, content: enc([["p", p(8)]])), locked: true)
        let v1 = await open(v(10000, [["p", p(5)]], at: 10), locked: true)
        let v2 = await open(v(10000, [["p", p(6)]], at: 20, content: enc([["word", "y"]])), locked: true)
        let cur = await open(v(10000, [["p", p(6)]], at: 30, content: enc([["word", "y"]])))
        XCTAssertTrue(v2.locked)
        asked = 0
        let unopened = ListVersionMerge.build(current: cur, picked: [v1], all: [cur, v2, v1, v0])
        XCTAssertEqual(unopened.first { $0.tag[1] == p(5) }!.status, .back, "without reading v2 it can't be told")
        let all = await ListVersionMerge.openForMerge([cur, v2, v1, v0], picked: [v1], decrypt: { try await self.decrypt($0) })
        XCTAssertEqual(asked, 1, "only the locked version newer than the oldest ticked one")
        XCTAssertTrue(all.first { $0.id == v0.id }!.locked)
        let rows = ListVersionMerge.build(current: cur, picked: [v1], all: all)
        let x = rows.first { $0.tag[1] == p(5) }!
        XCTAssertEqual(x.status, .removed); XCTAssertFalse(x.ticked); XCTAssertFalse(x.isPrivate)
    }

    func testUnreadNextVersionIsNotCalledARemoval() async {
        let v1 = await open(v(10000, [], at: 10, content: enc([["p", p(7)]])))
        let v2 = await open(v(10000, [["p", p(1)]], at: 20, content: "garbage"))
        let cur = await open(v(10000, [["p", p(1)], ["p", p(2)]], at: 30))
        let r = ListVersionMerge.build(current: cur, picked: [v1], all: [cur, v2, v1]).first { $0.tag[1] == p(7) }!
        XCTAssertEqual(r.status, .back); XCTAssertTrue(r.ticked)
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
}
