import XCTest
@testable import MediaLogic

final class GlobeZapsTests: XCTestCase {
    private let me = String(repeating: "0", count: 64)
    private let server = String(repeating: "5", count: 64)
    private let zapper = String(repeating: "a", count: 64)
    private let zapped = String(repeating: "b", count: 64)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // Zap requests signed with throwaway keys by go-nostr, the library
    // behind the app's verifier (`VerifyEventC`), as it printed them.
    private let signedZapper = "74dc4c285760501bf074a8c0f23188fc0fa85f408311fc3c474b8f76b488c84d"
    private let victim = "51a6f6ca66bc75f0dd2fbc883b409f1e74a49e9da6c58007bf54317a2e4418ff"
    private let signed = #"{"kind":9734,"id":"c7b03d8124c176ea8a8f8278bfb11c33abf47547a9de4e497cb74e81460d6b09","pubkey":"74dc4c285760501bf074a8c0f23188fc0fa85f408311fc3c474b8f76b488c84d","created_at":1799999990,"tags":[["p","bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"],["amount","21000"],["relays","wss://relay.example/x"]],"content":"for the bolt","sig":"eab3ef7d25b164e8b538ef8cec4274059cb66eb42df43334fc66f45786be470eed5d26485c40d83d352df80922ef433dc643e1cce48b1c6e73a57194e6f3cecf"}"#
    private let unsigned = #"{"kind":9734,"id":"c7b03d8124c176ea8a8f8278bfb11c33abf47547a9de4e497cb74e81460d6b09","pubkey":"74dc4c285760501bf074a8c0f23188fc0fa85f408311fc3c474b8f76b488c84d","created_at":1799999990,"tags":[["p","bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"],["amount","21000"],["relays","wss://relay.example/x"]],"content":"for the bolt"}"#
    private let badSig = #"{"kind":9734,"id":"c7b03d8124c176ea8a8f8278bfb11c33abf47547a9de4e497cb74e81460d6b09","pubkey":"74dc4c285760501bf074a8c0f23188fc0fa85f408311fc3c474b8f76b488c84d","created_at":1799999990,"tags":[["p","bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"],["amount","21000"],["relays","wss://relay.example/x"]],"content":"for the bolt","sig":"00b3ef7d25b164e8b538ef8cec4274059cb66eb42df43334fc66f45786be470eed5d26485c40d83d352df80922ef433dc643e1cce48b1c6e73a57194e6f3cecf"}"#
    private let otherSigner = #"{"kind":9734,"id":"c7b03d8124c176ea8a8f8278bfb11c33abf47547a9de4e497cb74e81460d6b09","pubkey":"74dc4c285760501bf074a8c0f23188fc0fa85f408311fc3c474b8f76b488c84d","created_at":1799999990,"tags":[["p","bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"],["amount","21000"],["relays","wss://relay.example/x"]],"content":"for the bolt","sig":"7ff617830f29e07e8fa4ec36daa2061170ca51802652f2d21dda08183dcffe2d62bad107893b0eb04a681bc5ec945ebcc1618c7d827bd05fa1987860fa1d389d"}"#
    private let duplicatePubkey = #"{"kind":9734,"id":"2f5b4b449b350d49d32afee5ae4a99f568d936250b780f14a9cf103f8bca15d2","pubkey":"51a6f6ca66bc75f0dd2fbc883b409f1e74a49e9da6c58007bf54317a2e4418ff","pubkey":"5c99b266d2c29ba7e86fcf598ad304ca04e8925f65d9cdc113487f95ac1898a3","created_at":1799999990,"tags":[["p","bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"],["amount","21000"],["relays","wss://relay.example/x"]],"content":"for the bolt","sig":"7ff617830f29e07e8fa4ec36daa2061170ca51802652f2d21dda08183dcffe2d62bad107893b0eb04a681bc5ec945ebcc1618c7d827bd05fa1987860fa1d389d"}"#
    /// The duplicate-key attack: an attacker's own validly signed request with
    /// the victim's pubkey put in front of theirs. go-nostr reads the last
    /// key and verified this raw text; Swift reads the first and would have
    /// drawn the victim.
    private let duplicateRawVerifiedByGo = true
    /// Each request as `canonicalRequest` rebuilds it from Swift's reading,
    /// and go-nostr's verdict on that exact text.
    private let rebuilt: [String: (String, Bool)] = [
        "signed": (#"{"content":"for the bolt","created_at":1799999990,"id":"c7b03d8124c176ea8a8f8278bfb11c33abf47547a9de4e497cb74e81460d6b09","kind":9734,"pubkey":"74dc4c285760501bf074a8c0f23188fc0fa85f408311fc3c474b8f76b488c84d","sig":"eab3ef7d25b164e8b538ef8cec4274059cb66eb42df43334fc66f45786be470eed5d26485c40d83d352df80922ef433dc643e1cce48b1c6e73a57194e6f3cecf","tags":[["p","bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"],["amount","21000"],["relays","wss://relay.example/x"]]}"#, true),
        "badSig": (#"{"content":"for the bolt","created_at":1799999990,"id":"c7b03d8124c176ea8a8f8278bfb11c33abf47547a9de4e497cb74e81460d6b09","kind":9734,"pubkey":"74dc4c285760501bf074a8c0f23188fc0fa85f408311fc3c474b8f76b488c84d","sig":"00b3ef7d25b164e8b538ef8cec4274059cb66eb42df43334fc66f45786be470eed5d26485c40d83d352df80922ef433dc643e1cce48b1c6e73a57194e6f3cecf","tags":[["p","bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"],["amount","21000"],["relays","wss://relay.example/x"]]}"#, false),
        "otherSigner": (#"{"content":"for the bolt","created_at":1799999990,"id":"c7b03d8124c176ea8a8f8278bfb11c33abf47547a9de4e497cb74e81460d6b09","kind":9734,"pubkey":"74dc4c285760501bf074a8c0f23188fc0fa85f408311fc3c474b8f76b488c84d","sig":"7ff617830f29e07e8fa4ec36daa2061170ca51802652f2d21dda08183dcffe2d62bad107893b0eb04a681bc5ec945ebcc1618c7d827bd05fa1987860fa1d389d","tags":[["p","bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"],["amount","21000"],["relays","wss://relay.example/x"]]}"#, false),
        "duplicatePubkey": (#"{"content":"for the bolt","created_at":1799999990,"id":"2f5b4b449b350d49d32afee5ae4a99f568d936250b780f14a9cf103f8bca15d2","kind":9734,"pubkey":"51a6f6ca66bc75f0dd2fbc883b409f1e74a49e9da6c58007bf54317a2e4418ff","sig":"7ff617830f29e07e8fa4ec36daa2061170ca51802652f2d21dda08183dcffe2d62bad107893b0eb04a681bc5ec945ebcc1618c7d827bd05fa1987860fa1d389d","tags":[["p","bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"],["amount","21000"],["relays","wss://relay.example/x"]]}"#, false),
    ]
    /// go-nostr's verdict on each raw request as it printed it.
    private var rawVerdicts: [String: Bool] {
        [signed: true, unsigned: false, badSig: false, otherSigner: false, duplicatePubkey: duplicateRawVerifiedByGo]
    }
    private var verdicts: [String: Bool] {
        rawVerdicts.merging(rebuilt.values.map { ($0.0, $0.1) }) { _, new in new }
    }
    /// Stands in for the app's verifier with go-nostr's recorded verdicts.
    /// The table is exact-match, on the raw and the rebuilt text alike, so
    /// it answers as the real verifier would whichever one it is handed.
    /// Anything not in it (the
    /// malformed cases, built here) passes, so the shape checks are proven
    /// on their own; `testTheRebuiltRequestsAreTheOnesRecorded` keeps the
    /// table and the code in step.
    private func verify(_ json: String) -> Bool { verdicts[json] ?? true }

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
        let arrival = GlobeArcs.arrival(receipt(signed), now: now, verifyZap: verify)
        XCTAssertEqual(arrival?.author, signedZapper)
        XCTAssertEqual(arrival?.targets, [zapped])
        XCTAssertEqual(arrival?.zap, true)
        XCTAssertEqual(arrival, GlobeArcs.zap(receipt(signed), now: now, verify: verify))
        // The verifier is handed the request as Swift read it, rebuilt.
        var seen: String?
        _ = GlobeArcs.zap(receipt(signed), now: now) { seen = $0; return true }
        XCTAssertEqual(seen, rebuilt["signed"]?.0)
    }

    private func parsed(_ json: String) -> [String: Any] {
        (try! JSONSerialization.jsonObject(with: Data(json.utf8))) as! [String: Any]
    }

    func testARequestWithoutItsProperFieldsIsntVerified() {
        var request = parsed(signed)
        request["id"] = "x"
        XCTAssertNil(GlobeArcs.canonicalRequest(request))
        request = parsed(signed)
        request["created_at"] = 1_799_999_990.5
        XCTAssertNil(GlobeArcs.canonicalRequest(request))
        request = parsed(signed)
        request["sig"] = nil
        XCTAssertNil(GlobeArcs.canonicalRequest(request))
        XCTAssertNotNil(GlobeArcs.canonicalRequest(parsed(signed)))
    }

    func testTheRebuiltRequestsAreTheOnesRecorded() {
        let raws = ["signed": signed, "unsigned": unsigned, "badSig": badSig,
                    "otherSigner": otherSigner, "duplicatePubkey": duplicatePubkey]
        for (name, json) in raws {
            XCTAssertEqual(GlobeArcs.canonicalRequest(parsed(json)), rebuilt[name]?.0, name)
        }
        // go-nostr drops an empty sig: an unsigned request has none, and
        // isn't even rebuilt for the check.
        XCTAssertNil(parsed(unsigned)["sig"])
        // created_at stays an integer, the way it was signed.
        XCTAssertTrue(rebuilt["signed"]!.0.contains(#""created_at":1799999990,"#))
    }

    func testAZapWhoseRequestIsntSignedByItsZapperDrawsNothing() {
        XCTAssertEqual(rebuilt["signed"]?.1, true)
        for (why, request) in [("unsigned", unsigned), ("garbage signature", badSig),
                               ("signed by someone else", otherSigner)] {
            XCTAssertNil(GlobeArcs.arrival(receipt(request), now: now, verifyZap: verify), why)
        }
        for name in ["badSig", "otherSigner"] { XCTAssertEqual(rebuilt[name]?.1, false, name) }
        // A key given twice: verified as Swift reads it (the victim), it fails.
        XCTAssertTrue(duplicateRawVerifiedByGo)
        XCTAssertEqual(parsed(duplicatePubkey)["pubkey"] as? String, victim)
        XCTAssertEqual(rebuilt["duplicatePubkey"]?.1, false)
        XCTAssertNil(GlobeArcs.arrival(receipt(duplicatePubkey), now: now, verifyZap: verify))
        // With no verifier at all, a zap draws nothing: the check can't be skipped.
        XCTAssertNil(GlobeArcs.arrival(receipt(signed), now: now))
    }

    func testABrokenReceiptDrawsNothing() {
        let cases: [(String, [String: Any])] = [
            ("no request", receipt(nil)),
            ("request isn't JSON", receipt("{not json")),
            ("request isn't a 9734", receipt(request(kind: 1))),
            ("request has no zapper", receipt(request(pubkey: ""))),
            ("request names someone else", receipt(request(p: [me]))),
            ("request names two people", receipt(request(p: [zapped, me]))),
            ("receipt names two people", receipt(signed, p: [zapped, me])),
            ("zapping yourself", receipt(request(p: [zapper]), p: [zapper])),
            ("bad id", receipt(signed, id: "x")),
        ]
        for (why, event) in cases {
            XCTAssertNil(GlobeArcs.arrival(event, now: now, verifyZap: verify), why)
        }
        // An old receipt is a relay catching up, not a zap now.
        var old = receipt(signed)
        old["created_at"] = now.timeIntervalSince1970 - GlobeArcs.maxAge - 1
        XCTAssertNil(GlobeArcs.arrival(old, now: now, verifyZap: verify))
    }

    func testABoltStrikesFlashesAndFadesQuickerThanAStar() {
        var board = GlobeArcs.Board()
        board.add(GlobeArcs.arrival(receipt(signed), now: now, verifyZap: verify)!)
        board.step(now: 0, me: me)
        let line = board.lines[0]
        XCTAssertTrue(line.zap)
        XCTAssertEqual(line.from, signedZapper)
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
