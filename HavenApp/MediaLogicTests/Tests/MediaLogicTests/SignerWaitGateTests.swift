import XCTest
@testable import MediaLogic

final class SignerWaitGateTests: XCTestCase {
    /// The DM queue's retry rounds, with `asks` counting signer requests:
    /// a round sends every waiting wrap through the gate, one at a time.
    private struct Queue {
        var gate = SignerWaitGate()
        var waiting: [String]
        var asks = 0

        mutating func process(_ id: String, signerUp: Bool) {
            guard gate.mayAsk(id) else { waiting.append(id); return }
            asks += 1
            if signerUp {
                if gate.answered(id) { release(signerUp: signerUp) }
            } else {
                gate.noAnswer()
                waiting.append(id)
            }
        }

        mutating func release(signerUp: Bool) {
            let all = waiting
            waiting = []
            for id in all { process(id, signerUp: signerUp) }
        }

        /// DMService.retryWaitingForSigner
        mutating func round(signerUp: Bool) {
            guard !waiting.isEmpty else { return }
            if gate.parked {
                let probe = waiting.removeLast()
                gate.probe(probe)
                process(probe, signerUp: signerUp)
            } else {
                release(signerUp: signerUp)
            }
        }
    }

    func testSilentSignerIsAskedOncePerRoundNotOncePerDM() {
        var q = Queue(waiting: (0..<200).map { "w\($0)" })
        q.round(signerUp: false)  // first pass, before anything parked
        for _ in 0..<8 { q.round(signerUp: false) }
        XCTAssertEqual(q.asks, 9, "1 per round; was 200 per round (1,800)")
        XCTAssertEqual(q.waiting.count, 200, "nothing lost")
    }

    func testAnsweredProbeReleasesEveryWaitingDM() {
        var q = Queue(waiting: (0..<200).map { "w\($0)" })
        q.round(signerUp: false)
        q.round(signerUp: true)
        XCTAssertEqual(q.asks, 1 + 200)
        XCTAssertTrue(q.waiting.isEmpty)
        XCTAssertEqual(q.gate, SignerWaitGate())
    }

    func testOnlyTheProbeIsAskedWhileItIsOut() {
        var gate = SignerWaitGate()
        gate.noAnswer()
        XCTAssertFalse(gate.mayAsk("a"))
        gate.probe("a")
        XCTAssertTrue(gate.mayAsk("a"))
        XCTAssertFalse(gate.mayAsk("b"), "a refresh during the probe asks nothing")
        XCTAssertFalse(gate.answered("b"))
        XCTAssertTrue(gate.answered("a"))
        XCTAssertTrue(gate.mayAsk("b"))
    }

    func testProbeWithNoAnswerParksAgain() {
        var gate = SignerWaitGate()
        gate.noAnswer()
        gate.probe("a")
        gate.noAnswer()
        XCTAssertTrue(gate.parked)
        XCTAssertNil(gate.probeId)
        XCTAssertFalse(gate.answered("a"))
    }

    func testAnswersOutsideAProbeChangeNothing() {
        var gate = SignerWaitGate()
        XCTAssertTrue(gate.mayAsk("a"))
        XCTAssertFalse(gate.answered("a"))
        XCTAssertEqual(gate, SignerWaitGate())
    }
}
