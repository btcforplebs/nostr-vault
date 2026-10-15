import XCTest
import simd
@testable import MediaLogic

final class GlobeArcsTests: XCTestCase {
    private let me = String(repeating: "0", count: 64)
    private func key(_ n: Int) -> String { String(format: "%064x", n * 0x1234567 + 1) }
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func note(_ n: Int, by author: String, to targets: [String] = [], kind: Int = 1,
                      age: TimeInterval = 5) -> [String: Any] {
        ["id": key(1000 + n), "pubkey": author, "kind": kind,
         "created_at": now.timeIntervalSince1970 - age, "tags": targets.map { ["p", $0] } + [["e", key(7), "", "mention"]]]
    }

    func testANoteToYouIsOneLineToYou() {
        let arrival = GlobeArcs.arrival(note(1, by: key(1), to: [me]), now: now)
        XCTAssertEqual(arrival?.targets, [me])
    }

    func testANoteNamingSeveralPeopleIsOneLineEachOnceWithoutTheAuthor() {
        let arrival = GlobeArcs.arrival(note(1, by: key(1), to: [key(2), key(3), key(2), key(1)]), now: now)
        XCTAssertEqual(arrival?.targets, [key(2), key(3)])
    }

    func testANoteNamingACrowdIsCapped() {
        let arrival = GlobeArcs.arrival(note(1, by: key(1), to: (2...20).map(key)), now: now)
        XCTAssertEqual(arrival?.targets.count, GlobeArcs.maxTargets)
    }

    private func event(_ n: Int, by author: String, kind: Int, tags: [[String]]) -> [String: Any] {
        ["id": key(1000 + n), "pubkey": author, "kind": kind, "created_at": now.timeIntervalSince1970 - 5, "tags": tags]
    }

    func testAReplyFliesToThePersonItAnswersNotTheWholeThread() {
        // root by 2, replied to by 3; 1 answers 3. NIP-10 tags list the
        // thread's people, root author first.
        let tags = [["e", key(50), "", "root", key(2)], ["e", key(51), "", "reply", key(3)],
                    ["p", key(2)], ["p", key(3)], ["p", key(4)]]
        let arrival = GlobeArcs.arrival(event(1, by: key(1), kind: 1, tags: tags), now: now)
        XCTAssertEqual(arrival?.targets, [key(3)])
        // A direct reply to the root names only the root.
        let direct = [["e", key(50), "", "root", key(2)], ["p", key(2)], ["p", key(4)]]
        XCTAssertEqual(GlobeArcs.arrival(event(2, by: key(1), kind: 1, tags: direct), now: now)?.targets, [key(2)])
        // Older clients leave the pubkey slot empty: the first p, as the feed reads it.
        let positional = [["e", key(50)], ["e", key(51)], ["p", key(3)], ["p", key(2)]]
        XCTAssertEqual(GlobeArcs.arrival(event(3, by: key(1), kind: 1, tags: positional), now: now)?.targets, [key(3)])
    }

    func testAReplyWeCantPlaceDoesntFlyIntoYou() {
        // About a fifth of real replies carry no p tag and no pubkey slot.
        // They used to have no targets, and the board flies those into you.
        let marked = [["e", key(50), "", "root"], ["e", key(51), "", "reply"]]
        XCTAssertNil(GlobeArcs.arrival(event(10, by: key(1), kind: 1, tags: marked), now: now))
        let positional = [["e", key(50)], ["e", key(51)]]
        XCTAssertNil(GlobeArcs.arrival(event(11, by: key(1), kind: 1, tags: positional), now: now))
        let comment = [["E", key(50)], ["K", "1"], ["e", key(51)], ["k", "1"]]
        XCTAssertNil(GlobeArcs.arrival(event(12, by: key(1), kind: 1111, tags: comment), now: now))
        // A plain note aimed at no one still lands on you.
        let plain = GlobeArcs.arrival(event(13, by: key(1), kind: 1, tags: []), now: now)
        XCTAssertEqual(plain?.targets, [])
        var board = GlobeArcs.Board()
        board.add(plain!)
        board.step(now: 0, me: me)
        XCTAssertEqual(board.lines.map(\.to), [me])
    }

    func testAPositionalReplyWithSeveralETagsFliesToTheFirstP() {
        // Deprecated positional form: the last unmarked e is the parent, and
        // with no pubkey slot the first p is who it answers.
        let tags = [["e", key(50)], ["e", key(52)], ["e", key(51)], ["p", key(3)], ["p", key(2)], ["p", key(4)]]
        XCTAssertEqual(GlobeArcs.arrival(event(14, by: key(1), kind: 1, tags: tags), now: now)?.targets, [key(3)])
        XCTAssertTrue(GlobeArcs.isReply(kind: 1, tags: tags))
        // A quote's mention e isn't a parent: not a reply.
        XCTAssertFalse(GlobeArcs.isReply(kind: 1, tags: [["e", key(50), "", "mention"], ["p", key(2)]]))
    }

    func testANIP22CommentReplyFliesToo() {
        // Amethyst, Ditto, Coracle and Snort reply to a note with a kind 1111
        // comment; these never flew.
        XCTAssertTrue(GlobeArcs.kinds.contains(NIP10Thread.commentKind))
        let tags = [["E", key(50), "", key(2)], ["K", "1"], ["P", key(2)],
                    ["e", key(51), "", key(3)], ["k", "1"], ["p", key(3)]]
        let arrival = GlobeArcs.arrival(event(4, by: key(1), kind: 1111, tags: tags), now: now)
        XCTAssertEqual(arrival?.author, key(1))
        XCTAssertEqual(arrival?.targets, [key(3)])
        // Without the pubkey slot, the lowercase p is the parent's author.
        let bare = [["E", key(50)], ["K", "1"], ["e", key(51)], ["k", "1"], ["p", key(3)]]
        XCTAssertEqual(GlobeArcs.arrival(event(5, by: key(1), kind: 1111, tags: bare), now: now)?.targets, [key(3)])
        // A comment on a video isn't a note reply.
        let video = [["E", key(52)], ["K", "21"], ["e", key(52)], ["k", "21"], ["p", key(3)]]
        XCTAssertNil(GlobeArcs.arrival(event(6, by: key(1), kind: 1111, tags: video), now: now))
    }

    func testAQuoteAndASelfReplyStillFlyToWhoTheyName() {
        // A quote's e is a mention: it flies to who it names, as before.
        let quote = [["e", key(50), "", "mention"], ["q", key(50)], ["p", key(2)]]
        XCTAssertEqual(GlobeArcs.arrival(event(7, by: key(1), kind: 1, tags: quote), now: now)?.targets, [key(2)])
        // Answering yourself in a thread: the others in it, not you.
        let selfReply = [["e", key(50), "", "reply", key(1)], ["p", key(1)], ["p", key(2)]]
        XCTAssertEqual(GlobeArcs.arrival(event(8, by: key(1), kind: 1, tags: selfReply), now: now)?.targets, [key(2)])
    }

    func testOnlyFreshNotesArrive() {
        XCTAssertNil(GlobeArcs.arrival(note(1, by: key(1), kind: 7), now: now))
        XCTAssertNil(GlobeArcs.arrival(note(1, by: key(1), age: GlobeArcs.maxAge + 1), now: now))
        XCTAssertNil(GlobeArcs.arrival(note(1, by: "nope"), now: now))
        XCTAssertNotNil(GlobeArcs.arrival(note(1, by: key(1)), now: now))
    }

    func testTheSameNoteFromTwoRelaysDrawsOnce() {
        var board = GlobeArcs.Board()
        let a = GlobeArcs.arrival(note(1, by: key(1), to: [me]), now: now)!
        board.add(a)
        board.add(a)
        board.step(now: 0, me: me)
        board.step(now: GlobeArcs.spacing * 2, me: me)
        XCTAssertEqual(board.lines.count, 1)
    }

    /// The globe redraws a frame again at the same instant (a face loading
    /// does it). A star let on that frame is still fading in, and it must
    /// not be dropped as faded out: it would never fly (Logen, 10/14).
    func testAStarLetOnSurvivesARedrawAtTheSameInstant() {
        var board = GlobeArcs.Board()
        board.add(GlobeArcs.arrival(note(1, by: key(1)), now: now)!)
        board.step(now: 100, me: me)
        board.step(now: 100, me: me)
        XCTAssertEqual(board.lines.count, 1)
        board.step(now: 100.01, me: me)
        XCTAssertEqual(board.lines.count, 1)
    }

    func testAStarIsDroppedOnceItHasFadedOut() {
        var board = GlobeArcs.Board()
        board.add(GlobeArcs.arrival(note(1, by: key(1)), now: now)!)
        board.step(now: 100, me: me)
        let end = 100 + GlobeArcs.travel + GlobeArcs.hold + GlobeArcs.fade
        board.step(now: end - 0.05, me: me)
        XCTAssertEqual(board.lines.count, 1)
        board.step(now: end + 0.05, me: me)
        XCTAssertTrue(board.lines.isEmpty)
    }

    func testANoteToNoOneFliesIntoYou() {
        var board = GlobeArcs.Board()
        board.add(GlobeArcs.arrival(note(1, by: key(1)), now: now)!)
        board.step(now: 0, me: me)
        XCTAssertEqual(board.lines.map(\.from), [key(1)])
        XCTAssertEqual(board.lines.map(\.to), [me])
        XCTAssertTrue(board.lines.allSatisfy(\.toMe))
    }

    func testYourOwnNoteToNoOneDrawsNothing() {
        var board = GlobeArcs.Board()
        board.add(GlobeArcs.arrival(note(1, by: me), now: now)!)
        board.step(now: 0, me: me)
        XCTAssertTrue(board.lines.isEmpty)
    }

    func testAReplyFliesBetweenItsPartiesNotIntoYou() {
        var board = GlobeArcs.Board()
        board.add(GlobeArcs.arrival(note(1, by: key(1), to: [key(2)]), now: now)!)
        board.step(now: 0, me: me)
        XCTAssertEqual(board.lines.map(\.to), [key(2)])
        XCTAssertFalse(board.lines.contains(where: \.toMe))
    }

    func testARepostFliesFromTheReposterToWhoTheyReposted() {
        let repost = GlobeArcs.arrival(note(1, by: key(1), to: [key(2)], kind: 6), now: now)
        XCTAssertEqual(repost?.author, key(1))
        XCTAssertEqual(repost?.targets, [key(2)])
        XCTAssertNotNil(GlobeArcs.arrival(note(2, by: key(1), to: [key(2)], kind: 16), now: now))
    }

    func testABigRequestIsSplitUnderTheRelaysSizeCap() {
        // His follows' reposts and the Discover feed as one REQ came to 170 KB,
        // and relay.btcforplebs.com refused it whole ("message too large").
        let authors = (0..<1_500).map(key)
        let filters: [[String: Any]] = stride(from: 0, to: authors.count, by: 500).map {
            ["kinds": [1, 6, 16], "since": 1, "authors": Array(authors[$0..<$0 + 500])]
        } + [["kinds": [1, 6, 16], "since": 1]]
        let one = try! JSONSerialization.data(withJSONObject: ["REQ", "arcs-x"] + filters)
        XCTAssertGreaterThan(one.count, 100_000)
        let requests = GlobeArcs.requests(filters, subId: "arcs-x")
        XCTAssertGreaterThan(requests.count, 1)
        var ids: [String] = [], sent: [[String: Any]] = []
        for text in requests {
            XCTAssertLessThanOrEqual(text.utf8.count, GlobeArcs.maxRequestBytes)
            let req = try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [Any]
            XCTAssertEqual(req[0] as? String, "REQ")
            ids.append(req[1] as! String)
            sent += req.dropFirst(2).map { $0 as! [String: Any] }
        }
        // Every filter goes, once, in order, each REQ under its own id.
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(sent.map { ($0["authors"] as? [String])?.first }, filters.map { ($0["authors"] as? [String])?.first })
        // A small REQ stays one message with the id it was given.
        let small = GlobeArcs.requests([["kinds": [1], "since": 1]], subId: "arcs-y")
        XCTAssertEqual(small.count, 1)
        XCTAssertTrue(small[0].hasPrefix("[\"REQ\",\"arcs-y\","))
        // A single filter past the cap still goes, on its own.
        XCTAssertEqual(GlobeArcs.requests(filters, subId: "z", maxBytes: 10).count, filters.count)
    }

    func testARepostWithNoPTagFliesIntoYou() {
        // Most reposts on some relays carry only the e tag: no one to point
        // at, so like any note aimed at no one it flies into you.
        for kind in [6, 16] {
            let repost = GlobeArcs.arrival(note(3 + kind, by: key(1), kind: kind), now: now)
            XCTAssertEqual(repost?.author, key(1))
            XCTAssertEqual(repost?.targets, [])
            var board = GlobeArcs.Board()
            board.add(repost!)
            board.step(now: 0, me: me)
            XCTAssertEqual(board.lines.map(\.to), [me])
            XCTAssertTrue(board.lines.allSatisfy(\.toMe))
        }
    }

    func testEachFeedSetsOutFromItsOwnShellWidestLast() {
        let follows: Set = [key(1), me], discover: Set = [key(2)]
        XCTAssertEqual(GlobeArcs.ring(of: key(1), follows: follows, discover: discover), .following)
        XCTAssertEqual(GlobeArcs.ring(of: me, follows: follows, discover: discover), .following)
        XCTAssertEqual(GlobeArcs.ring(of: key(2), follows: follows, discover: discover), .discover)
        XCTAssertEqual(GlobeArcs.ring(of: key(3), follows: follows, discover: discover), .global)
        let radii = GlobeArcs.Ring.allCases.map(\.radius)
        XCTAssertEqual(radii, radii.sorted())
        XCTAssertEqual(Set(radii).count, radii.count)
        // The line keeps its note's feed.
        var board = GlobeArcs.Board()
        var a = GlobeArcs.arrival(note(1, by: key(3)), now: now)!
        a.ring = .global
        board.add(a)
        board.step(now: 0, me: me)
        XCTAssertEqual(board.lines.map(\.ring), [.global])
    }

    func testABusyGlobalNeverPushesOutYourFollows() {
        var board = GlobeArcs.Board()
        var mine = GlobeArcs.arrival(note(0, by: key(1), to: [me]), now: now)!
        mine.ring = .following
        board.add(mine)
        for n in 1..<40 {
            var a = GlobeArcs.arrival(note(n, by: key(n + 100)), now: now)!
            a.ring = n % 3 == 0 ? .discover : .global
            board.add(a)
        }
        XCTAssertEqual(board.waiting.count, GlobeArcs.maxWaiting)
        XCTAssertTrue(board.waiting.contains { $0.id == mine.id })
        // Global gives way before Discover does.
        XCTAssertTrue(board.waiting.filter { $0.ring == .discover }.count >= GlobeArcs.maxWaiting - 1)
    }

    func testArrivalsAreSpacedOut() {
        var board = GlobeArcs.Board()
        board.add(GlobeArcs.arrival(note(1, by: key(1), to: [me]), now: now)!)
        board.add(GlobeArcs.arrival(note(2, by: key(2), to: [me]), now: now)!)
        XCTAssertNotNil(board.step(now: 0, me: me))
        XCTAssertNil(board.step(now: GlobeArcs.spacing / 2, me: me))
        XCTAssertNotNil(board.step(now: GlobeArcs.spacing, me: me))
        XCTAssertTrue(board.lines.allSatisfy(\.toMe))
    }

    func testABurstKeepsOnlyTheNewestWaiting() {
        var board = GlobeArcs.Board()
        for n in 0..<30 { board.add(GlobeArcs.arrival(note(n, by: key(n + 1), to: [me]), now: now)!) }
        XCTAssertEqual(board.waiting.count, GlobeArcs.maxWaiting)
        XCTAssertEqual(board.waiting.last?.id, key(1029))
    }

    func testStandingLinesNeverPassTheCap() {
        var board = GlobeArcs.Board()
        var t = 0.0
        for n in 0..<40 {
            board.add(GlobeArcs.arrival(note(n, by: key(n + 1), to: [key(100 + n), key(200 + n)]), now: now)!)
            board.step(now: t, me: me)
            XCTAssertLessThanOrEqual(board.lines.filter { $0.retired == nil }.count, GlobeArcs.maxLines)
            t += GlobeArcs.spacing
        }
        // Retired lines fade out quickly, so what is drawn stays near the cap.
        XCTAssertLessThanOrEqual(board.lines.count, GlobeArcs.maxLines + 2 * 2)
    }

    func testAStarTravelsLandsAndItsTrailFadesFirst() {
        let line = GlobeArcs.Line(note: key(9), from: key(1), to: me, toMe: true, born: 0, retired: nil)
        XCTAssertEqual(GlobeArcs.stage(of: line, at: 0).alpha, 0)
        let mid = GlobeArcs.stage(of: line, at: GlobeArcs.travel / 2)
        XCTAssertEqual(mid.head, 0.5, accuracy: 0.001)
        XCTAssertEqual(mid.trail, 1)
        XCTAssertFalse(GlobeArcs.hasLanded(line, at: GlobeArcs.travel / 2))
        XCTAssertTrue(GlobeArcs.hasLanded(line, at: GlobeArcs.travel))
        // Landed: the trail is gone soon after, the light where it landed stays.
        let held = GlobeArcs.stage(of: line, at: GlobeArcs.travel + GlobeArcs.trailFade)
        XCTAssertEqual(held.head, 1)
        XCTAssertEqual(held.trail, 0, accuracy: 1e-9)
        XCTAssertEqual(held.alpha, 1)
        let fading = GlobeArcs.stage(of: line, at: GlobeArcs.travel + GlobeArcs.hold + GlobeArcs.fade / 2)
        XCTAssertEqual(fading.alpha, 0.5, accuracy: 0.001)
        XCTAssertEqual(GlobeArcs.stage(of: line, at: GlobeArcs.life).alpha, 0, accuracy: 1e-9)
        // Reduce Motion: no flight, the same fades.
        let still = GlobeArcs.stage(of: line, at: 0.3, reduceMotion: true)
        XCTAssertEqual(still.head, 1)
        XCTAssertLessThan(still.trail, 1)
    }

    func testNotesHeldNeverOutgrowTheQueueAndLines() {
        // A long burst with no frames to move it on (a sheet open, another app
        // in front): only the newest few wait.
        var board = GlobeArcs.Board()
        for n in 0..<200 { board.add(GlobeArcs.arrival(note(n, by: key(n + 1), to: [me]), now: now)!) }
        XCTAssertEqual(board.waiting.count, GlobeArcs.maxWaiting)
        // Let on and faded out, they all go.
        var t = 0.0
        while !board.waiting.isEmpty { board.step(now: t, me: me); t += GlobeArcs.spacing }
        board.step(now: t + GlobeArcs.life, me: me)
        XCTAssertTrue(board.isIdle)
    }

    func testFadedLinesAreDropped() {
        var board = GlobeArcs.Board()
        board.add(GlobeArcs.arrival(note(1, by: key(1), to: [me]), now: now)!)
        board.step(now: 0, me: me)
        board.step(now: GlobeArcs.life + 0.01, me: me)
        XCTAssertTrue(board.isIdle)
    }

    func testLinesBendOffTheGlobeAndEndOnTheirPeople() {
        let a = SIMD3<Double>(1.6, 0, 0), b = SIMD3<Double>(0, 1.6, 0)
        XCTAssertEqual(simd_distance(GlobeArcs.point(from: a, to: b, at: 0), a), 0, accuracy: 1e-9)
        XCTAssertEqual(simd_distance(GlobeArcs.point(from: a, to: b, at: 1), b), 0, accuracy: 1e-9)
        // Lifted above the straight cut through the middle.
        XCTAssertGreaterThan(simd_length(GlobeArcs.point(from: a, to: b, at: 0.5)), simd_length((a + b) / 2))
        // A line into the core, and one straight across it, still bend.
        let toCore = GlobeArcs.point(from: a, to: .zero, at: 0.5)
        XCTAssertGreaterThan(simd_length(toCore - SIMD3(0.8, 0, 0)), 0.1)
        let across = GlobeArcs.point(from: a, to: -a, at: 0.5)
        XCTAssertGreaterThan(simd_length(across), 0.3)
    }

    func testALineIntoTheCoreBendsAcrossTheScreenNotTowardTheViewer() {
        let facing = SIMD3<Double>(0, 0, 1)
        let mid = GlobeArcs.point(from: SIMD3(1.6, 0, 0), to: .zero, at: 0.5, facing: facing)
        // The bend is sideways on screen (y), with none of it toward the camera (z).
        XCTAssertGreaterThan(abs(mid.y), 0.1)
        XCTAssertEqual(mid.z, 0, accuracy: 1e-9)
        // A line straight along the view still bends.
        let along = GlobeArcs.point(from: SIMD3(0, 0, 1.6), to: .zero, at: 0.5, facing: facing)
        XCTAssertGreaterThan(simd_length(SIMD2(along.x, along.y)), 0.1)
    }
}
