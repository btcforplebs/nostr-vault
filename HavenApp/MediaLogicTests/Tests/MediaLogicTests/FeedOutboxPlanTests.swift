import XCTest
@testable import MediaLogic

final class FeedOutboxPlanTests: XCTestCase {
    private let feed = ["wss://relay.primal.net", "wss://nos.lol"]

    /// A follow who writes to a feed relay is already covered and costs no
    /// extra socket; one who writes elsewhere gets that relay, asked only for them.
    func testOnlyFollowsTheFeedRelaysMissAreAskedElsewhere() {
        let plan = FeedOutboxPlan.plan(
            follows: ["a", "b", "c"],
            writeRelays: ["a": ["wss://nos.lol/"], "b": ["wss://relay.damus.io"], "c": []],
            feedRelays: feed)
        XCTAssertEqual(plan, ["wss://relay.damus.io": ["b"], FeedOutboxPlan.fallbackRelay: ["c"]])
    }

    /// Case and a trailing slash do not make a relay a different one.
    func testFeedRelayMatchIgnoresCaseAndTrailingSlash() {
        let plan = FeedOutboxPlan.plan(follows: ["a"], writeRelays: ["a": ["WSS://Relay.Primal.NET/"]],
                                       feedRelays: feed)
        XCTAssertTrue(plan.isEmpty)
    }

    /// The relay reaching the most uncovered follows is picked first, and a
    /// follow already reached is not asked again on a later pick.
    func testGreedyCoverPicksTheWidestRelayAndAsksEachFollowOnce() {
        let plan = FeedOutboxPlan.plan(
            follows: ["a", "b", "c", "d"],
            writeRelays: [
                "a": ["wss://relay.damus.io", "wss://x.example"],
                "b": ["wss://relay.damus.io"],
                "c": ["wss://relay.damus.io", "wss://y.example"],
                "d": ["wss://y.example"],
            ],
            feedRelays: feed)
        XCTAssertEqual(plan["wss://relay.damus.io"], ["a", "b", "c"])
        XCTAssertEqual(plan["wss://y.example"], ["d"])
        XCTAssertNil(plan["wss://x.example"])
        let asked = plan.values.flatMap { $0 }
        XCTAssertEqual(asked.count, Set(asked).count, "a follow is asked on one extra relay only")
    }

    func testExtraRelaysAreCapped() {
        var lists: [String: [String]] = [:]
        for i in 0..<20 { lists["p\(i)"] = ["wss://r\(i).example"] }
        let plan = FeedOutboxPlan.plan(follows: Array(lists.keys), writeRelays: lists, feedRelays: feed)
        XCTAssertEqual(plan.count, FeedOutboxPlan.maxExtraRelays)
    }

    /// Private and unreachable relays are somebody else's setup.
    func testUnreachableRelaysAreNeverPicked() {
        let lists = ["a": ["ws://plain.example", "wss://abc.onion", "wss://127.0.0.1:7777",
                           "wss://192.168.1.4", "wss://localhost", "wss://box.local"]]
        let plan = FeedOutboxPlan.plan(follows: ["a"], writeRelays: lists, feedRelays: feed)
        XCTAssertEqual(plan, [FeedOutboxPlan.fallbackRelay: ["a"]], "no usable relay = no list")
    }

    /// nos.lol and nostr.mom were down on 2026-10-04 while feed relays; a
    /// follow reached only through one of them was not reached at all.
    func testADownFeedRelayReachesNobody() {
        let lists = ["a": ["wss://nos.lol", "wss://relay.damus.io"]]
        XCTAssertTrue(FeedOutboxPlan.plan(follows: ["a"], writeRelays: lists, feedRelays: feed).isEmpty)
        let plan = FeedOutboxPlan.plan(follows: ["a"], writeRelays: lists, feedRelays: feed,
                                       unreachableRelays: ["wss://nos.lol/"])
        XCTAssertEqual(plan, ["wss://relay.damus.io": ["a"]])
        let onlyDown = FeedOutboxPlan.plan(follows: ["b"], writeRelays: ["b": ["wss://relay.damus.io"]],
                                           feedRelays: feed, unreachableRelays: ["wss://relay.damus.io"])
        XCTAssertEqual(onlyDown, [FeedOutboxPlan.fallbackRelay: ["b"]], "never pick a down relay")
    }

    /// Follows with no relay list go to the fallback, which also takes any
    /// listed follow it reaches — so they are not asked twice.
    func testUnlistedFollowsGoToTheFallbackOnce() {
        let fb = FeedOutboxPlan.fallbackRelay
        let plan = FeedOutboxPlan.plan(follows: ["a", "b", "c"],
                                       writeRelays: ["b": [fb, "wss://relay.damus.io"], "c": ["wss://relay.damus.io"]],
                                       feedRelays: feed)
        XCTAssertEqual(plan[fb], ["a", "b"])
        XCTAssertEqual(plan["wss://relay.damus.io"], ["c"])
        XCTAssertTrue(FeedOutboxPlan.plan(follows: ["a"], writeRelays: [:], feedRelays: feed + [fb]).isEmpty,
                      "a fallback already among the feed relays costs nothing")
        XCTAssertTrue(FeedOutboxPlan.plan(follows: ["a"], writeRelays: [:], feedRelays: feed, fallbackRelay: nil).isEmpty)
    }

    func testTheFallbackCountsTowardTheCap() {
        var lists: [String: [String]] = [:]
        for i in 0..<20 { lists["p\(i)"] = ["wss://r\(i).example"] }
        let plan = FeedOutboxPlan.plan(follows: Array(lists.keys) + ["unlisted"], writeRelays: lists, feedRelays: feed)
        XCTAssertEqual(plan.count, FeedOutboxPlan.maxExtraRelays)
        XCTAssertEqual(plan[FeedOutboxPlan.fallbackRelay], ["unlisted"])
    }

    /// Same inputs, same relays: dictionary order must not change the pick.
    func testTiesAreBrokenTheSameWayEveryTime() {
        let lists = ["a": ["wss://b.example"], "b": ["wss://a.example"]]
        for _ in 0..<20 {
            let plan = FeedOutboxPlan.plan(follows: ["a", "b"], writeRelays: lists, feedRelays: feed, maxExtraRelays: 1)
            XCTAssertEqual(Array(plan.keys), ["wss://a.example"])
        }
    }
}
