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
         "created_at": now.timeIntervalSince1970 - age, "tags": targets.map { ["p", $0] } + [["e", key(7)]]]
    }

    func testANoteToYouIsOneLineToYou() {
        let arrival = GlobeArcs.arrival(note(1, by: key(1), to: [me]), now: now)
        XCTAssertEqual(arrival?.targets, [me])
    }

    func testAReplyIsOneLinePerPersonOnceEachWithoutTheAuthor() {
        let arrival = GlobeArcs.arrival(note(1, by: key(1), to: [key(2), key(3), key(2), key(1)]), now: now)
        XCTAssertEqual(arrival?.targets, [key(2), key(3)])
    }

    func testABigReplyIsCapped() {
        let arrival = GlobeArcs.arrival(note(1, by: key(1), to: (2...20).map(key)), now: now)
        XCTAssertEqual(arrival?.targets.count, GlobeArcs.maxTargets)
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

    func testANoteToNoOneOnlyLightsItsAuthor() {
        var board = GlobeArcs.Board()
        board.add(GlobeArcs.arrival(note(1, by: key(1)), now: now)!)
        board.step(now: 0, me: me)
        XCTAssertTrue(board.lines.isEmpty)
        XCTAssertEqual(board.pulses.map(\.key), [key(1)])
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

    func testANotesPreviewIsItsFirstLineWithWords() {
        XCTAssertEqual(GlobeArcs.firstLine("https://x.io/a.jpg\n\n  gm   nostr  friends \nsecond"), "gm nostr friends")
        XCTAssertEqual(GlobeArcs.firstLine("nostr:nevent1abc"), "")
        let long = String(repeating: "word ", count: 60)
        let cut = GlobeArcs.firstLine(long)
        XCTAssertTrue(cut.hasSuffix("…"))
        XCTAssertLessThanOrEqual(cut.count, GlobeArcs.previewLength + 1)
        XCTAssertFalse(cut.dropLast().hasSuffix(" "))
        let arrival = GlobeArcs.arrival(note(1, by: key(1)).merging(["content": "hello there\nmore"]) { $1 }, now: now)
        XCTAssertEqual(arrival?.text, "hello there")
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
