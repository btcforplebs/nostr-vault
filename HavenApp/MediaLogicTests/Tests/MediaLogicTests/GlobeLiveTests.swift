import XCTest
@testable import MediaLogic

final class GlobeLiveTests: XCTestCase {
    private let me = String(repeating: "0", count: 64)
    private let a = String(repeating: "a", count: 64)
    private let b = String(repeating: "b", count: 64)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func event(_ kind: Int, _ tags: [[String]], id: String = String(repeating: "c", count: 64)) -> [String: Any] {
        ["id": id, "pubkey": a, "kind": kind, "created_at": now.timeIntervalSince1970 - 5, "tags": tags]
    }

    func testLiveArrivalsStartOnButStayOffForWhoeverTurnedThemOff() {
        let defaults = UserDefaults(suiteName: "GlobeLiveTests-\(UUID())")!
        // A new install, or someone who never touched the antenna.
        XCTAssertTrue(LiveArcsSetting.isOn(defaults))
        defaults.set(false, forKey: LiveArcsSetting.key)
        XCTAssertFalse(LiveArcsSetting.isOn(defaults))
        defaults.set(true, forKey: LiveArcsSetting.key)
        XCTAssertTrue(LiveArcsSetting.isOn(defaults))
        // Its own key, apart from the feeds' and sorts' switches.
        let keys = [LiveArcsSetting.key, LiveArcsSetting.spinKey] + GlobeArcs.Ring.allCases.map(LiveArcsSetting.key)
            + GlobeArcs.Sort.allCases.map(LiveArcsSetting.key)
        XCTAssertEqual(Set(keys).count, keys.count)
    }

    func testEachArrivalKnowsWhatItIs() {
        XCTAssertEqual(GlobeArcs.arrival(event(1, [["p", b]]), now: now)?.sort, .note)
        XCTAssertEqual(GlobeArcs.arrival(event(1, [["e", String(repeating: "d", count: 64), "", "reply", b]]), now: now)?.sort, .reply)
        XCTAssertEqual(GlobeArcs.arrival(event(6, [["e", String(repeating: "d", count: 64)], ["p", b]]), now: now)?.sort, .repost)
        // A quote is a new note.
        XCTAssertEqual(GlobeArcs.arrival(event(1, [["e", String(repeating: "d", count: 64), "", "mention"], ["p", b]]), now: now)?.sort, .note)
        // Answering yourself in a thread is still a reply.
        XCTAssertEqual(GlobeArcs.arrival(event(1, [["e", String(repeating: "d", count: 64), "", "reply", a], ["p", b]]), now: now)?.sort, .reply)
    }

    func testAReactionFliesFromTheReactorToWhoeverTheyReactedTo() {
        let note = String(repeating: "d", count: 64)
        // NIP-25: the last p tag is the person reacted to.
        let reaction = GlobeArcs.arrival(event(7, [["e", note], ["p", me], ["p", b]]), now: now)
        XCTAssertEqual(reaction?.sort, .reaction)
        XCTAssertEqual(reaction?.author, a)
        XCTAssertEqual(reaction?.targets, [b])
        XCTAssertEqual(reaction?.zap, false)
        // One we can't place doesn't fly, so it never lands on you by default.
        XCTAssertNil(GlobeArcs.arrival(event(7, [["e", note]]), now: now))
        XCTAssertNil(GlobeArcs.arrival(event(7, [["p", b]]), now: now))
        XCTAssertNil(GlobeArcs.arrival(event(7, [["e", note], ["p", "npub-not-hex"]]), now: now))
        // Nor does reacting to yourself.
        XCTAssertNil(GlobeArcs.arrival(event(7, [["e", note], ["p", a]]), now: now))
        // Too old is a relay catching up.
        var old = event(7, [["e", note], ["p", b]])
        old["created_at"] = now.timeIntervalSince1970 - GlobeArcs.maxAge - 1
        XCTAssertNil(GlobeArcs.arrival(old, now: now))
        // Its line keeps what it is, so it draws as a smaller star.
        var board = GlobeArcs.Board()
        board.add(reaction!)
        board.step(now: 0, me: me)
        XCTAssertEqual(board.lines.map(\.to), [b])
        XCTAssertEqual(board.lines.first?.sort, .reaction)
    }

    func testTheSwitchesPickWhatFlies() {
        var show = GlobeArcs.Show()
        XCTAssertTrue(GlobeArcs.Sort.allCases.allSatisfy(show.allows))
        show.replies = false
        show.zaps = false
        XCTAssertEqual(GlobeArcs.Sort.allCases.filter(show.allows), [.note, .repost, .reaction])
        show.reactions = false
        XCTAssertFalse(show.allows(.reaction))
    }

    func testABiggerZapStrikesHarder() {
        let strengths = [0, 21, 1_000, 21_000, 100_000, 10_000_000].map { GlobeArcs.zapStrength(sats: $0) }
        XCTAssertEqual(strengths, strengths.sorted())
        XCTAssertEqual(strengths.first, 0.15)
        XCTAssertEqual(strengths.last, 1)
        XCTAssertEqual(GlobeArcs.zapStrength(sats: 100_000), 1)
        // A strong zap forks twice, a light one once.
        let seed = GlobeBolt.seed("zap")
        XCTAssertEqual(GlobeBolt.forks(seed: seed, strength: 0.2).count, 1)
        XCTAssertEqual(GlobeBolt.forks(seed: seed, strength: 0.9).count, 2)
        // The flicker stutters while it flashes and holds still after.
        let levels = (0..<16).map { GlobeBolt.flicker(seed: seed, frame: $0) }
        XCTAssertTrue(levels.allSatisfy { (0.55...1).contains($0) })
        XCTAssertGreaterThan(Set(levels).count, 8)
        XCTAssertEqual(GlobeBolt.flicker(seed: seed, frame: -1), 1)
        // The board carries the strength to the bolt.
        var board = GlobeArcs.Board()
        board.add(GlobeArcs.Arrival(id: String(repeating: "e", count: 64), author: a, targets: [b], zap: true, sort: .zap, strength: 0.8))
        board.step(now: 0, me: me)
        XCTAssertEqual(board.lines.first?.strength, 0.8)
    }

    func testTheGlobeHoldsStillWithSpinningOff() {
        var camera = GlobeCamera()
        camera.keepsDrifting = true
        camera.drifts = false
        var t = 0.0
        while t < 30 { t += 1 / 30; camera.step(dt: 1 / 30, now: t, reduceMotion: false) }
        XCTAssertEqual(camera.orientation.vector, GlobeCamera().orientation.vector)
        XCTAssertFalse(camera.wantsFrames(now: t, reduceMotion: false))
        // On again, it drifts.
        camera.drifts = true
        let before = camera.orientation
        camera.step(dt: 1 / 30, now: t + 1 / 30, reduceMotion: false)
        XCTAssertNotEqual(camera.orientation.vector, before.vector)
    }
}
