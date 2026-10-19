import XCTest
@testable import MediaLogic

/// The storm: every arrival at once, drawn in batches, over the feed's own
/// connections (Logen, 10/15).
final class GlobeStormTests: XCTestCase {
    private func key(_ n: Int) -> String { String(format: "%064x", n * 0x1234567 + 1) }
    private let me = String(repeating: "0", count: 64)

    // MARK: The feed skips the globe's messages on a shared connection

    func testAGlobeMessageIsTheGlobesAndAFeedMessageOnTheSameSocketIsNot() {
        let event = #"{"id":"\#(key(1))","pubkey":"\#(key(2))","kind":1,"created_at":1,"tags":[],"content":"hi","sig":""}"#
        // The globe's: the feed never takes these in, nor puts them in your relay.
        XCTAssertTrue(GlobeArcs.isGlobeMessage(#"["EVENT","arcs-1a2b3c4d",\#(event)]"#))
        XCTAssertTrue(GlobeArcs.isGlobeMessage(#"["EVENT","arcs-1a2b3c4d-2",\#(event)]"#))
        XCTAssertTrue(GlobeArcs.isGlobeMessage(#"[ "EVENT", "arcs-1a2b3c4d", \#(event)]"#))
        XCTAssertTrue(GlobeArcs.isGlobeMessage(#"["EOSE","arcs-1a2b3c4d"]"#))
        XCTAssertTrue(GlobeArcs.isGlobeMessage(#"["CLOSED","arcs-1a2b3c4d","error: too many"]"#))
        // The feed's own, on the same connection: still the feed's.
        for sub in ["feed-wss://relay.example", "m-1", "rx-2", "zaps-3", "tfetch-4"] {
            XCTAssertFalse(GlobeArcs.isGlobeMessage(#"["EVENT","\#(sub)",\#(event)]"#), sub)
        }
        XCTAssertFalse(GlobeArcs.isGlobeMessage(#"["NOTICE","arcs- is not a sub id here"]"#))
        XCTAssertFalse(GlobeArcs.isGlobeMessage(#"["OK","\#(key(1))",true,""]"#))
        XCTAssertFalse(GlobeArcs.isGlobeMessage(""))
        // A note whose text mentions arcs- is not the globe's.
        XCTAssertFalse(GlobeArcs.isGlobeMessage(#"["EVENT","feed-x",{"content":"arcs-"}]"#))
    }

    /// JSON allows any whitespace between tokens, and a relay may send it:
    /// a globe EVENT the check misses goes into the feed and your relay
    /// (Tron, 10/15).
    func testAGlobeMessageIsCaughtWhateverWhitespaceTheRelaySends() {
        let event = #"{"id":"\#(key(1))","pubkey":"\#(key(2))","kind":1,"created_at":1,"tags":[],"content":"hi","sig":""}"#
        for gap in ["\t", "\n", "\r\n", " \t\r\n ", String(repeating: " ", count: 64), String(repeating: "\n", count: 50)] {
            let shown = gap.debugDescription
            XCTAssertTrue(GlobeArcs.isGlobeMessage("[\(gap)\"EVENT\",\(gap)\"arcs-1a2b3c4d\",\(gap)\(event)]"), "EVENT " + shown)
            XCTAssertTrue(GlobeArcs.isGlobeMessage("\(gap)[\"EVENT\"\(gap),\"arcs-1a2b3c4d\",\(event)\(gap)]"), "lead " + shown)
            XCTAssertTrue(GlobeArcs.isGlobeMessage("[\"EOSE\",\(gap)\"arcs-1a2b3c4d\"]"), "EOSE " + shown)
            XCTAssertTrue(GlobeArcs.isGlobeMessage("[\"CLOSED\",\(gap)\"arcs-1a2b3c4d\",\"\"]"), "CLOSED " + shown)
            // The feed's own, spaced the same way, stay the feed's.
            for sub in ["feed-wss://relay.example", "m-1", "rx-2"] {
                XCTAssertFalse(GlobeArcs.isGlobeMessage("[\(gap)\"EVENT\",\(gap)\"\(sub)\",\(gap)\(event)]"), sub + " " + shown)
            }
            XCTAssertFalse(GlobeArcs.isGlobeMessage("[\"NOTICE\",\(gap)\"arcs-1a2b3c4d\"]"), "NOTICE " + shown)
            XCTAssertFalse(GlobeArcs.isGlobeMessage("[\"EVENT\",\(gap)\"feed-x\",{\"content\":\"arcs-1\"}]"), "content " + shown)
        }
        // A sub id the relay escapes is still read as itself.
        XCTAssertTrue(GlobeArcs.isGlobeMessage(#"["EVENT","arcs\u002d1a2b3c4d",\#(event)]"#))
        // Not JSON, or not an array: not the globe's.
        XCTAssertFalse(GlobeArcs.isGlobeMessage(#"["EVENT","arcs-1"#))
        XCTAssertFalse(GlobeArcs.isGlobeMessage(#"{"EVENT":"arcs-1"}"#))
    }

    func testEveryGlobeRequestIsUnderTheGlobePrefix() {
        let filters: [[String: Any]] = (0..<4).map { n in ["kinds": [1], "authors": (0..<500).map { key($0 + n * 500) }] }
        let requests = GlobeArcs.requests(filters, subId: GlobeArcs.subscriptionPrefix + "abcd1234")
        XCTAssertGreaterThan(requests.count, 1)
        for request in requests {
            let array = try? JSONSerialization.jsonObject(with: Data(request.utf8)) as? [Any]
            XCTAssertTrue((array?[1] as? String)?.hasPrefix(GlobeArcs.subscriptionPrefix) == true)
        }
        // Every reply to them is the globe's.
        XCTAssertEqual(GlobeArcs.closes(for: requests).count, requests.count)
    }

    func testClosingOnlyEverClosesTheGlobesSubscriptions() {
        let mine = GlobeArcs.requests([["kinds": [1]]], subId: "arcs-abcd1234")
        let feeds = GlobeArcs.requests([["kinds": [1]]], subId: "feed-wss://relay.example")
        let closes = GlobeArcs.closes(for: mine + feeds)
        XCTAssertEqual(closes, [#"["CLOSE","arcs-abcd1234"]"#])
    }

    /// Two links share a socket, and a CLOSEd subscription's answers can
    /// still come in after the app comes back: each link reads only its own,
    /// or a backlog flies through the new link as a burst.
    func testALinkReadsOnlyItsOwnSubscriptionsAnswers() {
        let event = #"{"id":"\#(key(1))","pubkey":"\#(key(2))","kind":1,"created_at":1,"tags":[],"content":"hi","sig":""}"#
        let filters: [[String: Any]] = (0..<4).map { n in ["kinds": [1], "authors": (0..<500).map { key($0 + n * 500) }] }
        let requests = GlobeArcs.requests(filters, subId: "arcs-abcd1234")
        let ids = GlobeArcs.subscriptions(of: requests)
        XCTAssertEqual(ids.count, requests.count)
        for id in ids {
            XCTAssertEqual(GlobeArcs.event(in: #"["EVENT","\#(id)",\#(event)]"#, ids: ids)?["id"] as? String, key(1))
        }
        // Another link's, an old CLOSEd one's, the feed's, and not an EVENT.
        XCTAssertNil(GlobeArcs.event(in: #"["EVENT","arcs-ffff0000",\#(event)]"#, ids: ids))
        XCTAssertNil(GlobeArcs.event(in: #"["EVENT","feed-x",\#(event)]"#, ids: ids))
        XCTAssertNil(GlobeArcs.event(in: #"["EOSE","\#(ids.first!)"]"#, ids: ids))
        XCTAssertNil(GlobeArcs.event(in: "", ids: ids))
        // A feed REQ is no sub id of the globe's.
        XCTAssertEqual(GlobeArcs.subscriptions(of: [#"["CLOSE","arcs-1"]"#]), [])
    }

    /// A reconnect, or the app coming back, asks from then: what was missed
    /// meanwhile never replays as a burst of stars.
    func testAskingAgainAsksFromNowAndKeepsTheRestOfEachFilter() {
        let storm = GlobeArcs.storm(rings: [.following], show: .init(), follows: (0..<3).map(key), since: 100)
        let toMe: [String: Any] = ["kinds": [1], "since": 100, "#p": [me]]
        let again = GlobeArcs.filters(storm + [toMe], since: 5_000)
        XCTAssertEqual(again.count, storm.count + 1)
        for filter in again { XCTAssertEqual(filter["since"] as? Int, 5_000) }
        XCTAssertEqual(again[0]["authors"] as? [String], (0..<3).map(key).sorted())
        XCTAssertEqual(again.last?["#p"] as? [String], [me])
        // The ids stay put, so CLOSE still ends what was sent.
        let first = GlobeArcs.requests(storm, subId: "arcs-abcd1234")
        let later = GlobeArcs.requests(GlobeArcs.filters(storm, since: 1_800_000_000), subId: "arcs-abcd1234")
        XCTAssertEqual(GlobeArcs.subscriptions(of: first), GlobeArcs.subscriptions(of: later))
    }

    // MARK: What the globe asks each relay for

    func testDiscoverAndGlobalAreOneAuthorlessFilterSoTheWholeWebFits() {
        let follows = (0..<1_200).map(key)
        for rings: Set<GlobeArcs.Ring> in [[.discover], [.global], [.following, .discover, .global]] {
            let filters = GlobeArcs.storm(rings: rings, show: .init(), follows: follows, since: 100)
            XCTAssertEqual(filters.count, 1)
            XCTAssertNil(filters[0]["authors"])
            XCTAssertEqual(Set(filters[0]["kinds"] as? [Int] ?? []), [1, 1111, 7, 6, 16, GlobeArcs.zapKind])
            XCTAssertEqual(filters[0]["since"] as? Int, 100)
        }
    }

    func testFollowingAloneKeepsToItsAuthors() {
        let follows = (0..<1_200).map(key)
        let filters = GlobeArcs.storm(rings: [.following], show: .init(), follows: follows, since: 100)
        let byAuthor = filters.filter { $0["authors"] != nil }
        XCTAssertEqual(byAuthor.map { ($0["authors"] as? [String])?.count }, [500, 500, 200])
        // Zap receipts carry the LNURL server's key: one filter of their own.
        XCTAssertEqual(filters.filter { $0["authors"] == nil }.map { $0["kinds"] as? [Int] }, [[GlobeArcs.zapKind]])
    }

    func testASwitchedOffSortIsNeverAskedFor() {
        var show = GlobeArcs.Show()
        show.reactions = false
        show.zaps = false
        show.reposts = false
        let kinds = GlobeArcs.storm(rings: [.global], show: show, follows: [], since: 0).first?["kinds"] as? [Int]
        XCTAssertEqual(kinds, [1, 1111])
        let none = GlobeArcs.Show(notes: false, replies: false, reposts: false, reactions: false, zaps: false)
        XCTAssertTrue(GlobeArcs.storm(rings: [.global], show: none, follows: [], since: 0).isEmpty)
        XCTAssertTrue(GlobeArcs.storm(rings: [], show: .init(), follows: [], since: 0).isEmpty)
    }

    // MARK: Drawing a storm cheaply

    func testOpacitiesFallIntoAFewBands() {
        XCTAssertEqual(GlobeArcs.band(0), 0)
        XCTAssertEqual(GlobeArcs.band(0.005), 0)
        XCTAssertEqual(GlobeArcs.band(0.02), 1)
        XCTAssertEqual(GlobeArcs.band(1), GlobeArcs.alphaBands)
        XCTAssertEqual(GlobeArcs.band(3), GlobeArcs.alphaBands)
        let bands = Set(stride(from: 0.0, through: 1, by: 0.001).map(GlobeArcs.band))
        XCTAssertEqual(bands.count, GlobeArcs.alphaBands + 1)
        for a in stride(from: 0.05, through: 1, by: 0.01) {
            XCTAssertEqual(GlobeArcs.bandAlpha(GlobeArcs.band(a)), a, accuracy: 0.5 / Double(GlobeArcs.alphaBands) + 1e-9)
        }
        XCTAssertLessThan(GlobeArcs.arcSamples(lines: 300), GlobeArcs.arcSamples(lines: 10))
    }

    func testOnlyTheNewestLinesGetFaces() {
        var board = GlobeArcs.Board()
        for n in 0..<100 {
            board.add(GlobeArcs.Arrival(id: key(5000 + n), author: key(n + 1), targets: [key(n + 200)]))
        }
        board.step(now: 0, me: me)
        let faces = board.faceKeys(limit: GlobeArcs.maxArcFaces, except: me)
        XCTAssertEqual(faces.count, GlobeArcs.maxArcFaces)
        XCTAssertEqual(faces.first, key(100))
        XCTAssertFalse(faces.contains(key(1)))
        // The core never gets a second face.
        var toMe = GlobeArcs.Board()
        toMe.add(GlobeArcs.Arrival(id: key(9000), author: key(1), targets: []))
        toMe.step(now: 0, me: me)
        XCTAssertEqual(toMe.faceKeys(limit: 5, except: me), [key(1)])
    }

    func testAQuietGlobeDrawsSlowAndABusyOneAtFullRate() {
        var board = GlobeArcs.Board()
        for n in 0..<(GlobeArcs.busyLines - 1) { board.add(GlobeArcs.Arrival(id: key(n), author: key(n + 1), targets: [me])) }
        board.step(now: 0, me: me)
        XCTAssertFalse(board.isBusy)
        board.add(GlobeArcs.Arrival(id: key(999), author: key(2), targets: [me]))
        XCTAssertTrue(board.isBusy)
    }

    func testTheSeenListForgetsOnlyPastItsCap() {
        var board = GlobeArcs.Board()
        for n in 0..<(GlobeArcs.Board.seenCap + 10) { board.add(GlobeArcs.Arrival(id: key(n), author: key(1), targets: [me])) }
        board.step(now: 0, me: me)
        // A recent one sent again by another relay is still a repeat.
        board.add(GlobeArcs.Arrival(id: key(GlobeArcs.Board.seenCap), author: key(1), targets: [me]))
        XCTAssertTrue(board.waiting.isEmpty)
        // The very first was forgotten to make room.
        board.add(GlobeArcs.Arrival(id: key(0), author: key(1), targets: [me]))
        XCTAssertEqual(board.waiting.count, 1)
    }

    // MARK: Debug counters

    func testTheRateCountsEachNoteOnceOverTheLastMinute() {
        var meter = GlobeArcs.RateMeter()
        meter.record("a", at: 0)
        meter.record("a", at: 1)
        meter.record("b", at: 30)
        XCTAssertEqual(meter.perMinute(at: 31), 2)
        XCTAssertEqual(meter.perMinute(at: 61), 1)
        XCTAssertEqual(meter.perMinute(at: 91), 0)
        // Forgotten past the minute, a repeat counts again.
        meter.record("a", at: 92)
        XCTAssertEqual(meter.perMinute(at: 92), 1)
    }

    func testFrameStatsReportAverageAndP95() {
        var stats = GlobeArcs.FrameStats()
        for n in 1...100 { stats.record(work: Double(n) / 1000, gap: 1.0 / 60) }
        XCTAssertEqual(GlobeArcs.FrameStats.percentile(stats.work, 0.95), 0.095, accuracy: 0.0011)
        XCTAssertTrue(stats.summary.hasPrefix("work 50.5/"))
        XCTAssertTrue(stats.summary.contains("gap 16.7/16.7 ms"))
    }
}
