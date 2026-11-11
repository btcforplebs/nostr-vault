import XCTest
@testable import MediaLogic

private struct TestNote: ThreadGroupable {
    let id: String
    let authorPubkey: String
    let createdAt: Date
    let parentEventId: String?
    let tags: [[String]]

    init(_ id: String, at seconds: TimeInterval, parent: String? = nil, root: String? = nil, author: String = "alice") {
        self.id = id
        self.authorPubkey = author
        self.createdAt = Date(timeIntervalSince1970: seconds)
        self.parentEventId = parent
        var tags: [[String]] = []
        if let root { tags.append(["e", root, "", "root"]) }
        if let parent, parent != root { tags.append(["e", parent, "", "reply"]) }
        self.tags = tags
    }
}

/// A feed switch in threaded layout groups the new feed off the main thread
/// (`FeedThreadRegroup.offMain`) instead of synchronously on it. The grouping
/// must come out exactly as the synchronous path's did.
@MainActor
final class FeedThreadRegroupTests: XCTestCase {
    /// A feed with every shape the grouping handles: replies in and out of
    /// order, a nested reply, a root only the caches hold, a root never
    /// loaded, a conversation a blocked author started (its root only in the
    /// caches), and ties on time. A blocked author's own posts never reach
    /// the grouping: the feed filter drops them first.
    private let feed: [TestNote] = [
        TestNote("r3", at: 900, parent: "a", root: "a", author: "bob"),
        TestNote("b", at: 850),
        TestNote("x1", at: 800, parent: "cachedRoot", root: "cachedRoot"),
        TestNote("a", at: 700, author: "carol"),
        TestNote("r1", at: 650, parent: "a", root: "a"),
        TestNote("r2", at: 640, parent: "r1", root: "a", author: "dave"),
        TestNote("m1", at: 600, parent: "missing", root: "missing"),
        TestNote("ctx", at: 540, parent: "blockedCtx", root: "blockedCtx"),
        TestNote("t1", at: 500),
        TestNote("t2", at: 500),
        TestNote("t3", at: 500, parent: "t1", root: "t1"),
    ]
    private let caches: [String: TestNote] = [
        "cachedRoot": TestNote("cachedRoot", at: 100),
        "blockedCtx": TestNote("blockedCtx", at: 90, author: "mallory"),
    ]
    private let blocked: Set<String> = ["mallory"]

    private func grouped(keepFeedOrder: Bool) -> [FeedThread<TestNote>] {
        let feed = feed, caches = caches, blocked = blocked
        let index = Dictionary(uniqueKeysWithValues: feed.map { ($0.id, $0) })
        return FeedThreadGrouping.groupFeed(notes: feed, keepFeedOrder: keepFeedOrder, blocked: blocked) {
            caches[$0] ?? index[$0]
        }
    }

    private func shape(_ threads: [FeedThread<TestNote>]) -> [String] {
        threads.map { thread in
            "\(thread.rootId)|root:\(thread.root?.id ?? "-")|"
                + thread.entries.map { "\($0.id)@\($0.depth)" }.joined(separator: ",")
        }
    }

    func testOffMainOrderMatchesTheSynchronousPath() async {
        for keep in [false, true] {
            let sync = grouped(keepFeedOrder: keep)
            XCTAssertFalse(sync.isEmpty)
            var offMain: [FeedThread<TestNote>]?
            let feed = feed, caches = caches, blocked = blocked
            let task = FeedThreadRegroup.offMain({
                let index = Dictionary(uniqueKeysWithValues: feed.map { ($0.id, $0) })
                return FeedThreadGrouping.groupFeed(notes: feed, keepFeedOrder: keep, blocked: blocked) {
                    caches[$0] ?? index[$0]
                }
            }, isCurrent: { true }, apply: { offMain = $0 })
            await task.value
            XCTAssertEqual(shape(offMain ?? []), shape(sync), "keepFeedOrder \(keep)")
        }
        // The fixture really exercises the cache lookup and the blocked rule.
        let shown = shape(grouped(keepFeedOrder: false))
        XCTAssertTrue(shown.contains("cachedRoot|root:cachedRoot|cachedRoot@0,x1@1"))
        XCTAssertTrue(shown.contains("missing|root:-|m1@1"))
        XCTAssertFalse(shown.joined().contains("blockedCtx"))
        XCTAssertFalse(shown.joined().contains("ctx@"))
    }

    /// The bar: the grouping itself runs off the main thread. Before, a feed
    /// switch grouped synchronously on it.
    func testGroupingRunsOffTheMainThread() async {
        var ranOnMain: Bool?
        var applied = false
        let task = FeedThreadRegroup.offMain({ Thread.isMainThread },
                                             isCurrent: { true },
                                             apply: { ranOnMain = $0; applied = true })
        await task.value
        XCTAssertTrue(applied)
        XCTAssertEqual(ranOnMain, false)
    }

    /// A grouping overtaken by a newer one is dropped, not applied.
    func testOvertakenGroupingIsDropped() async {
        var generation = 1
        let mine = generation
        var applied: [Int] = []
        let gate = DispatchSemaphore(value: 0)
        let task = FeedThreadRegroup.offMain({ () -> Int in _ = gate.wait(timeout: .now() + 2); return mine },
                                             isCurrent: { mine == generation },
                                             apply: { applied.append($0) })
        generation += 1 // a newer rebuild started while this one grouped
        gate.signal()
        await task.value
        XCTAssertTrue(applied.isEmpty)
    }

    /// Tron's #1911 fix: notes stream in faster than one grouping takes, so
    /// each grouping is overtaken by the next before it lands. A cleared feed
    /// still shows the first one that finishes, not nothing until the stream
    /// goes quiet. Each step is (generation started, generations finished).
    func testStreamingFillShowsAGroupingWhileTheFeedIsEmpty() {
        var current = 0, applied = 0, shown: [Int] = []
        let floor = 1 // the switch's own grouping is generation 1
        for gen in 1...5 {
            current = gen // a newer rebuild started before the last one landed
            let finished = gen - 1
            guard finished >= floor else { continue }
            if FeedThreadRegroup.shouldApply(generation: finished, current: current, floor: floor,
                                             lastApplied: applied, showingNothing: shown.isEmpty) {
                applied = finished
                shown.append(finished)
            }
        }
        XCTAssertEqual(shown, [1], "the first finished grouping fills the empty feed")
        // Once something shows, overtaken results drop as before; the current one applies.
        XCTAssertFalse(FeedThreadRegroup.shouldApply(generation: 4, current: 5, floor: floor,
                                                     lastApplied: applied, showingNothing: false))
        XCTAssertTrue(FeedThreadRegroup.shouldApply(generation: 5, current: 5, floor: floor,
                                                    lastApplied: applied, showingNothing: false))
    }

    /// A grouping of the feed just left never fills the new, empty one, and an
    /// older result never replaces a newer one already shown (even an empty one).
    func testOldFeedAndOlderResultsNeverFillTheEmptyFeed() {
        XCTAssertFalse(FeedThreadRegroup.shouldApply(generation: 3, current: 5, floor: 4,
                                                     lastApplied: 0, showingNothing: true))
        XCTAssertFalse(FeedThreadRegroup.shouldApply(generation: 4, current: 6, floor: 4,
                                                     lastApplied: 5, showingNothing: true))
        XCTAssertTrue(FeedThreadRegroup.shouldApply(generation: 5, current: 6, floor: 4,
                                                    lastApplied: 4, showingNothing: true))
    }
}
