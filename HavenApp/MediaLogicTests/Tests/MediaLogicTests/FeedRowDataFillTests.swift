import XCTest
@testable import MediaLogic

/// A feed switch, played through the row-data path the feed view runs:
/// rows drawn on the first frame resolve through `FeedRowDrafts`, then the
/// debounced `FeedRowDataFill.reconcile` files them. Counts every resolve.
final class FeedRowDataFillTests: XCTestCase {
    private struct Note { let id: String; var parent: String? = nil }
    private struct Row: Equatable { let id: String; let version: Int; var hasParent = false }

    private var resolves: [String: Int] = [:]
    private var version = 1
    private var loaded: Set<String> = []

    private func resolve(_ note: Note) -> Row {
        resolves[note.id, default: 0] += 1
        return Row(id: note.id, version: version, hasParent: note.parent.map(loaded.contains) ?? false)
    }

    private func reconcile(_ notes: [Note], cache: [String: Row], drafts: inout FeedRowDrafts<Row>) -> [String: Row] {
        FeedRowDataFill.reconcile(
            notes: notes, id: \.id, cache: cache, drafts: drafts.take(),
            needsRepair: { note, row in !row.hasParent && (note.parent.map(self.loaded.contains) ?? false) },
            resolve: resolve)
    }

    private func feed(_ prefix: String, _ count: Int) -> [Note] {
        (0..<count).map { Note(id: "\(prefix)\($0)") }
    }

    /// The bar: a switch to a 200-note feed with 6 rows on screen resolves
    /// exactly those 6, each once. Before, reconcile resolved all 200 and the
    /// 6 drawn rows a second time (206 resolves).
    func testSwitchResolvesOnlyDrawnRowsAndEachOnce() {
        let old = feed("old", 50)
        var drafts = FeedRowDrafts<Row>()
        var cache = Dictionary(uniqueKeysWithValues: old.map { ($0.id, Row(id: $0.id, version: 0)) })
        let new = feed("new", 200)

        // First frame of the new feed: the six rows on screen, drawn twice
        // (the switch publishes more than once before reconcile runs).
        for _ in 0..<2 {
            for note in new.prefix(6) {
                let row = drafts.row(id: note.id, cached: cache[note.id]) { resolve(note) }
                XCTAssertEqual(row.id, note.id, "a drawn row shows its own note's data")
            }
        }
        cache = reconcile(new, cache: cache, drafts: &drafts)

        XCTAssertEqual(resolves.values.reduce(0, +), 6)
        XCTAssertEqual(Set(resolves.keys), Set(new.prefix(6).map(\.id)))
        XCTAssertTrue(resolves.values.allSatisfy { $0 == 1 }, "no drawn row resolves twice")
        XCTAssertEqual(Set(cache.keys), Set(new.prefix(6).map(\.id)), "old feed's rows are dropped, undrawn rows are not filed")
        XCTAssertTrue(drafts.rows.isEmpty)

        // Scrolling on: the next row resolves once when drawn and is filed next time.
        let next = new[6]
        _ = drafts.row(id: next.id, cached: cache[next.id]) { resolve(next) }
        _ = drafts.row(id: next.id, cached: cache[next.id]) { resolve(next) }
        cache = reconcile(new, cache: cache, drafts: &drafts)
        XCTAssertEqual(resolves[next.id], 1)
        XCTAssertNotNil(cache[next.id])
        XCTAssertEqual(resolves.values.reduce(0, +), 7)
    }

    /// Switching back to a feed whose rows are still cached resolves nothing.
    func testKeptRowsAreReusedNotResolved() {
        let notes = feed("n", 30)
        var drafts = FeedRowDrafts<Row>()
        let cache = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, Row(id: $0.id, version: 0)) })
        for note in notes.prefix(6) { _ = drafts.row(id: note.id, cached: cache[note.id]) { resolve(note) } }
        let out = reconcile(notes, cache: cache, drafts: &drafts)
        XCTAssertEqual(out, cache)
        XCTAssertTrue(resolves.isEmpty)
    }

    /// No stale parent: a reply drawn before its parent loaded is resolved
    /// again at reconcile once the parent is there, and only then.
    func testDrawnReplyIsRepairedWhenItsParentArrives() {
        let reply = Note(id: "reply", parent: "p")
        var drafts = FeedRowDrafts<Row>()
        _ = drafts.row(id: reply.id, cached: nil) { resolve(reply) }
        var cache = reconcile([reply], cache: [:], drafts: &drafts)
        XCTAssertEqual(resolves[reply.id], 1, "parent still missing: no pointless second resolve")
        XCTAssertEqual(cache[reply.id]?.hasParent, false)

        loaded.insert("p")
        cache = reconcile([reply], cache: cache, drafts: &drafts)
        XCTAssertEqual(cache[reply.id]?.hasParent, true)
        XCTAssertEqual(resolves[reply.id], 2)
    }

    /// A change that reaches a drawn row before it is filed drops its draft,
    /// so the row is never left showing the older data.
    func testRemoveDropsOnlyDraftedIds() {
        var drafts = FeedRowDrafts<Row>()
        _ = drafts.row(id: "a", cached: nil) { resolve(Note(id: "a")) }
        XCTAssertEqual(drafts.remove(["a", "b"]), ["a"])
        version = 2
        let again = drafts.row(id: "a", cached: nil) { resolve(Note(id: "a")) }
        XCTAssertEqual(again.version, 2)
    }

    /// The cache wins over a draft, so an update filed in the cache shows.
    func testCachedRowWinsOverDraft() {
        var drafts = FeedRowDrafts<Row>()
        _ = drafts.row(id: "a", cached: nil) { resolve(Note(id: "a")) }
        let filed = Row(id: "a", version: 9)
        XCTAssertEqual(drafts.row(id: "a", cached: filed) { resolve(Note(id: "a")) }, filed)
        XCTAssertEqual(reconcile([Note(id: "a")], cache: ["a": filed], drafts: &drafts)["a"], filed)
    }
}
