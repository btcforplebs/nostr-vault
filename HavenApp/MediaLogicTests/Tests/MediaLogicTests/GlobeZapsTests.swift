import XCTest
@testable import MediaLogic

final class GlobeZapsTests: XCTestCase {
    private let me = String(repeating: "0", count: 64)
    private let server = String(repeating: "5", count: 64)
    private let zapper = String(repeating: "a", count: 64)
    private let zapped = String(repeating: "b", count: 64)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func request(pubkey: String? = nil, kind: Int = 9734, p: [String]? = nil) -> String {
        var r: [String: Any] = ["kind": kind, "content": "", "created_at": 1_799_999_990,
                                "tags": (p ?? [zapped]).map { ["p", $0] } + [["amount", "21000"]]]
        if let pk = pubkey ?? Optional(zapper), !pk.isEmpty { r["pubkey"] = pk }
        return String(data: try! JSONSerialization.data(withJSONObject: r), encoding: .utf8)!
    }

    private func receipt(_ description: String?, p: [String]? = nil, id: String = String(repeating: "c", count: 64)) -> [String: Any] {
        var tags: [[String]] = (p ?? [zapped]).map { ["p", $0] } + [["bolt11", "lnbc210n1..."]]
        if let description { tags.append(["description", description]) }
        return ["id": id, "pubkey": server, "kind": 9735, "created_at": now.timeIntervalSince1970 - 3, "tags": tags]
    }

    func testAZapFliesFromTheZapperNotTheServerToThePersonZapped() {
        let arrival = GlobeArcs.arrival(receipt(request()), now: now)
        XCTAssertEqual(arrival?.author, zapper)
        XCTAssertEqual(arrival?.targets, [zapped])
        XCTAssertEqual(arrival?.zap, true)
        XCTAssertEqual(arrival, GlobeArcs.zap(receipt(request()), now: now))
    }

    func testAForgedOrBrokenReceiptDrawsNothing() {
        let cases: [(String, [String: Any])] = [
            ("no request", receipt(nil)),
            ("request isn't JSON", receipt("{not json")),
            ("request isn't a 9734", receipt(request(kind: 1))),
            ("request has no zapper", receipt(request(pubkey: ""))),
            ("request names someone else", receipt(request(p: [me]))),
            ("request names two people", receipt(request(p: [zapped, me]))),
            ("receipt names two people", receipt(request(), p: [zapped, me])),
            ("zapping yourself", receipt(request(p: [zapper]), p: [zapper])),
            ("bad id", receipt(request(), id: "x")),
        ]
        for (why, event) in cases {
            XCTAssertNil(GlobeArcs.arrival(event, now: now), why)
        }
        // An old receipt is a relay catching up, not a zap now.
        var old = receipt(request())
        old["created_at"] = now.timeIntervalSince1970 - GlobeArcs.maxAge - 1
        XCTAssertNil(GlobeArcs.arrival(old, now: now))
    }

    func testABoltStrikesFlashesAndFadesQuickerThanAStar() {
        var board = GlobeArcs.Board()
        board.add(GlobeArcs.arrival(receipt(request()), now: now)!)
        board.step(now: 0, me: me)
        let line = board.lines[0]
        XCTAssertTrue(line.zap)
        XCTAssertEqual(line.from, zapper)
        XCTAssertEqual(line.to, zapped)
        // Across almost at once, full while it flashes, then an afterglow.
        XCTAssertEqual(GlobeArcs.stage(of: line, at: GlobeArcs.boltStrike).head, 1)
        XCTAssertEqual(GlobeArcs.stage(of: line, at: GlobeArcs.boltStrike + GlobeArcs.boltFlash).alpha, 1)
        let glow = GlobeArcs.stage(of: line, at: GlobeArcs.boltStrike + GlobeArcs.boltFlash + GlobeArcs.boltGlow / 2).alpha
        XCTAssertGreaterThan(glow, 0)
        XCTAssertLessThan(glow, 0.5)
        XCTAssertTrue(GlobeArcs.isGone(line, at: GlobeArcs.boltLife))
        XCTAssertLessThan(GlobeArcs.boltLife, GlobeArcs.travel + GlobeArcs.hold + GlobeArcs.fade)
        // Reduce Motion: there at once.
        XCTAssertEqual(GlobeArcs.stage(of: line, at: 0.01, reduceMotion: true).head, 1)
        // It shares the stars' cap.
        for n in 0..<30 {
            board.add(GlobeArcs.Arrival(id: String(format: "%064x", n + 1), author: zapper, targets: [zapped], zap: true))
            board.step(now: Double(n + 1) * GlobeArcs.spacing, me: me)
        }
        XCTAssertLessThanOrEqual(board.lines.filter { $0.retired == nil }.count, GlobeArcs.maxLines)
    }

    func testTheBoltIsJaggedPinnedAtBothEndsAndPlainUnderReduceMotion() {
        let seed = GlobeBolt.seed("zap-id")
        let a = GlobeBolt.offsets(seed: seed, frame: 3, reduceMotion: false)
        XCTAssertEqual(a.count, GlobeBolt.segments + 1)
        XCTAssertEqual(a.first, 0)
        XCTAssertEqual(a.last, 0)
        XCTAssertTrue(a.allSatisfy { abs($0) <= GlobeBolt.reach })
        XCTAssertGreaterThan(a.map(abs).max()!, GlobeBolt.reach * 0.2)
        // The same frame draws the same bolt; the next frame flickers.
        XCTAssertEqual(a, GlobeBolt.offsets(seed: seed, frame: 3, reduceMotion: false))
        XCTAssertNotEqual(a, GlobeBolt.offsets(seed: seed, frame: 4, reduceMotion: false))
        // Its afterglow holds one shape.
        XCTAssertEqual(GlobeBolt.frame(at: 1.0, flickers: false), GlobeBolt.frame(at: 1.5, flickers: false))
        XCTAssertTrue(GlobeBolt.offsets(seed: seed, frame: 3, reduceMotion: true).allSatisfy { $0 == 0 })
        let fork = GlobeBolt.fork(seed: seed)
        XCTAssertTrue((1..<GlobeBolt.segments).contains(fork.from))
    }

    func testTheZapFilterKeepsTheRequestUnderTheSizeCap() {
        let filter: [String: Any] = ["kinds": [GlobeArcs.zapKind], "since": 1]
        let requests = GlobeArcs.requests([filter], subId: "arcs-x")
        XCTAssertEqual(requests.count, 1)
        XCTAssertLessThan(requests[0].utf8.count, GlobeArcs.maxRequestBytes)
    }
}
