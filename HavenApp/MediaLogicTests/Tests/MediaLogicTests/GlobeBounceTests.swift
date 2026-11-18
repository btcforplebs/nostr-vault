import XCTest
import simd
@testable import MediaLogic

/// Step 7 of RESEARCH/NV_ONE_WOT_GATE.md: notes the gate refuses fly in red,
/// bounce off your web's shell and fade; Reduce Motion fades in place.
final class GlobeBounceTests: XCTestCase {
    let me = String(repeating: "a", count: 64)
    let friend = String(repeating: "b", count: 64)
    let stranger = String(repeating: "c", count: 64)
    let blocked = String(repeating: "d", count: 64)

    private var web: WebGate.Web { WebGate.Web(own: [me], web: [friend], blocked: [blocked]) }

    private func event(_ author: String, id: String, content: String = "gm") -> [String: Any] {
        ["id": id, "pubkey": author, "kind": 1, "content": content, "tags": [["p", me]],
         "created_at": Date().timeIntervalSince1970]
    }

    private func arrival(_ author: String, id: String) -> GlobeArcs.Arrival {
        GlobeArcs.Arrival(id: id, author: author, targets: [me], ring: .following)
    }

    // MARK: The gate's verdicts

    func testVerdictsMapToFlights() {
        XCTAssertEqual(GlobeArcs.flight(for: .inside), .fly)
        XCTAssertEqual(GlobeArcs.flight(for: .hop3), .fly)
        XCTAssertEqual(GlobeArcs.flight(for: .outside), .bounce)
        XCTAssertEqual(GlobeArcs.flight(for: .blocked), .none)
    }

    func testYourWebFliesAStrangerBouncesABlockOrMuteShowsNothing() {
        let id1 = String(repeating: "1", count: 64), id2 = String(repeating: "2", count: 64)
        let id3 = String(repeating: "3", count: 64), id4 = String(repeating: "4", count: 64)
        let flies = GlobeArcs.judged(arrival(friend, id: id1), event: event(friend, id: id1), in: web, reach: .web)
        XCTAssertEqual(flies?.bounced, false)
        XCTAssertEqual(flies?.ring, .following)

        let bounces = GlobeArcs.judged(arrival(stranger, id: id2), event: event(stranger, id: id2), in: web, reach: .web)
        XCTAssertEqual(bounces?.bounced, true)
        XCTAssertEqual(bounces?.ring, .global, "a stranger sets out from the outer haze")

        XCTAssertNil(GlobeArcs.judged(arrival(blocked, id: id3), event: event(blocked, id: id3), in: web, reach: .web))

        let muted = WebGate.Web(own: [me], web: [friend],
                                mutes: MuteList(publicTags: [["word", "spam"]]))
        XCTAssertNil(GlobeArcs.judged(arrival(friend, id: id4), event: event(friend, id: id4, content: "buy spam"),
                                      in: muted, reach: .web), "a muted word is gone, not red")
    }

    func testEveryoneReachLetsAStrangerIn() {
        let id = String(repeating: "5", count: 64)
        let out = GlobeArcs.judged(arrival(stranger, id: id), event: event(stranger, id: id), in: web, reach: .everyone)
        XCTAssertEqual(out?.bounced, false)
    }

    // MARK: The board

    func testABouncedNoteIsOneRedLineNoBoltNoFace() {
        var board = GlobeArcs.Board()
        var a = GlobeArcs.Arrival(id: String(repeating: "6", count: 64), author: stranger,
                                  targets: [me, friend], ring: .global, zap: true, sort: .zap)
        a.bounced = true
        board.add(a)
        board.step(now: 0, me: me)
        XCTAssertEqual(board.lines.count, 1)
        XCTAssertTrue(board.lines[0].bounced)
        XCTAssertFalse(board.lines[0].zap, "a refused zap bounces as a star")
        XCTAssertTrue(board.faceKeys(limit: 10, except: me).isEmpty, "no face for a refused stranger")
        XCTAssertEqual(GlobeArcs.faceAlpha(of: board.lines[0], at: 0.5), 0)
    }

    // MARK: Timing

    private var line: GlobeArcs.Line {
        GlobeArcs.Line(note: "n", from: stranger, to: me, toMe: true, ring: .global, born: 0, bounced: true)
    }

    func testFliesInToTheShellThenBouncesBackAndFades() {
        let mid = GlobeArcs.stage(of: line, at: GlobeArcs.bounceIn / 2)
        XCTAssertGreaterThan(mid.head, 0)
        XCTAssertLessThan(mid.head, 1)
        XCTAssertEqual(mid.alpha, 1, accuracy: 1e-9)

        let atShell = GlobeArcs.stage(of: line, at: GlobeArcs.bounceIn)
        XCTAssertEqual(atShell.head, 1, accuracy: 1e-9)

        let back = GlobeArcs.stage(of: line, at: GlobeArcs.bounceIn + GlobeArcs.bounceReflect / 2)
        XCTAssertLessThan(back.head, 1, "moving back out")
        XCTAssertGreaterThan(back.head, 1 - GlobeArcs.bounceBack)
        XCTAssertLessThan(back.alpha, 1)

        let end = GlobeArcs.stage(of: line, at: GlobeArcs.bounceLife)
        XCTAssertEqual(end.head, 1 - GlobeArcs.bounceBack, accuracy: 1e-9)
        XCTAssertEqual(end.alpha, 0, accuracy: 1e-9)
        XCTAssertEqual(end.landing, 0, "never lands")
        XCTAssertFalse(GlobeArcs.hasLanded(line, at: 10))
        XCTAssertFalse(GlobeArcs.isGone(line, at: GlobeArcs.bounceLife - 0.01))
        XCTAssertTrue(GlobeArcs.isGone(line, at: GlobeArcs.bounceLife))
        XCTAssertEqual(GlobeArcs.bounceReflect, 0.35, "the ~0.35 s reflect in the spec")
    }

    func testReduceMotionFadesInPlaceOnTheShell() {
        for t in stride(from: 0.0, through: GlobeArcs.bounceLife, by: 0.05) {
            let s = GlobeArcs.stage(of: line, at: t, reduceMotion: true)
            XCTAssertEqual(s.head, 1, "no flight, no bounce")
            XCTAssertEqual(s.trail, 0)
        }
        XCTAssertEqual(GlobeArcs.stage(of: line, at: 0, reduceMotion: true).alpha, 0, accuracy: 1e-9)
        XCTAssertEqual(GlobeArcs.stage(of: line, at: GlobeArcs.bounceLife / 2, reduceMotion: true).alpha, 1, accuracy: 1e-9)
        XCTAssertEqual(GlobeArcs.stage(of: line, at: GlobeArcs.bounceLife, reduceMotion: true).alpha, 0, accuracy: 1e-9)
    }

    func testAnArrivalStarIsUnchanged() {
        var plain = line
        plain.bounced = false
        XCTAssertEqual(GlobeArcs.stage(of: plain, at: 3).landing, GlobeArcs.stage(of: plain, at: 3).landing)
        XCTAssertTrue(GlobeArcs.hasLanded(plain, at: GlobeArcs.travel))
        XCTAssertFalse(GlobeArcs.isGone(plain, at: GlobeArcs.bounceLife))
    }

    // MARK: The shell

    func testShellHitIsWhereTheCurveMeetsTheShell() {
        let a = SIMD3(TrustMap.outerRadius, 0, 0), b = SIMD3(0.0, 0, 0)
        let t = GlobeArcs.shellHit(from: a, to: b)
        XCTAssertGreaterThan(t, 0)
        XCTAssertLessThan(t, 1)
        let p = GlobeArcs.point(from: a, to: b, at: t)
        XCTAssertEqual(simd_length(p), GlobeArcs.bounceShell, accuracy: 0.01)
        // Just before it, still outside.
        XCTAssertGreaterThan(simd_length(GlobeArcs.point(from: a, to: b, at: t - 0.02)), GlobeArcs.bounceShell)
    }

    func testShellHitFallsBackToHalfway() {
        // Two points out in the haze: the curve never comes in to the shell.
        let a = SIMD3(TrustMap.outerRadius, 0, 0), b = SIMD3(0, TrustMap.outerRadius, 0)
        XCTAssertEqual(GlobeArcs.shellHit(from: a, to: b, radius: 0.2), 0.5)
        XCTAssertEqual(GlobeArcs.shellHit(from: SIMD3(0.5, 0, 0), to: b), 0.5)
    }

    // MARK: The counter

    func testCounterCountsEachNoteOnceOverTheLastHour() {
        var log = GlobeArcs.BounceLog()
        XCTAssertTrue(log.record("x", at: 0))
        XCTAssertFalse(log.record("x", at: 10), "a second relay's copy")
        log.record("y", at: 100)
        XCTAssertEqual(log.count(at: 200), 2)
        XCTAssertEqual(log.count(at: 3_600 + 50), 1, "x is over an hour old")
        XCTAssertEqual(log.count(at: 3_600 + 101), 0)
        XCTAssertTrue(log.record("x", at: 4_000), "gone from the hour, it counts again")
        log.clear()
        XCTAssertEqual(log.count(at: 4_000), 0)
        XCTAssertEqual(GlobeArcs.bounceLabel(3), "3 bounced in the last hour")
    }

    func testCounterIsCapped() {
        var log = GlobeArcs.BounceLog()
        for i in 0..<(GlobeArcs.BounceLog.cap + 10) { log.record("\(i)", at: 1) }
        XCTAssertEqual(log.count(at: 2), GlobeArcs.BounceLog.cap)
    }
}
