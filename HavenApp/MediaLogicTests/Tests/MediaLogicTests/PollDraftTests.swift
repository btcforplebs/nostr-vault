import XCTest
@testable import MediaLogic

/// Writing a poll: what makes a draft postable, and the NIP-88 tags it
/// becomes, read back through the same parser the feed uses.
final class PollDraftTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func draft(_ question: String = "Ship it?", _ options: [String] = ["Yes", "No"]) -> PollDraft {
        var d = PollDraft()
        d.question = question
        d.options = options
        return d
    }

    func testNeedsAQuestionAndTwoDifferentOptions() {
        XCTAssertTrue(draft().isComplete(now: now))
        XCTAssertFalse(draft("  ").isComplete(now: now))
        XCTAssertFalse(draft("Q", ["Yes", " "]).isComplete(now: now))
        XCTAssertFalse(draft("Q", ["Yes", "yes "]).isComplete(now: now))
        XCTAssertTrue(draft("Q", ["Yes", "", "No"]).isComplete(now: now))
        XCTAssertFalse(draft("Q", (1...11).map { "o\($0)" }).isComplete(now: now))
    }

    func testEndTimeMustBeAhead() {
        var d = draft()
        d.endsAt = now.addingTimeInterval(-1)
        XCTAssertFalse(d.isComplete(now: now))
        d.endsAt = now.addingTimeInterval(3600)
        XCTAssertTrue(d.isComplete(now: now))
    }

    func testTagsRoundTripThroughTheParser() {
        var d = draft(" Ship it? ", ["Yes", "", " No "])
        d.type = .multiple
        d.endsAt = Date(timeIntervalSince1970: 1_800_003_600)
        var ids = ["aaa", "aaa", "bbb"].makeIterator()
        let tags = d.tags(relays: ["wss://relay.one", "WSS://RELAY.ONE", "ws://localhost:4869", "wss://relay.two"],
                          makeId: { ids.next()! })
        XCTAssertEqual(tags, [
            ["option", "aaa", "Yes"], ["option", "bbb", "No"],
            ["relay", "wss://relay.one"], ["relay", "wss://relay.two"],
            ["polltype", "multiplechoice"], ["endsAt", "1800003600"],
        ])
        let poll = NIP88Poll.Poll(id: "x", pubkey: "y", kind: 1068, content: d.trimmedQuestion, tags: tags)
        XCTAssertEqual(poll?.question, "Ship it?")
        XCTAssertEqual(poll?.options.map(\.label), ["Yes", "No"])
        XCTAssertEqual(poll?.type, .multiple)
        XCTAssertEqual(poll?.relays, ["wss://relay.one", "wss://relay.two"])
    }

    func testSingleChoiceWithNoEndAndCappedRelays() {
        let relays = (1...6).map { "wss://r\($0).example" }
        let tags = draft().tags(relays: relays)
        XCTAssertEqual(tags.filter { $0[0] == "relay" }.count, PollDraft.maxRelays)
        XCTAssertTrue(tags.contains(["polltype", "singlechoice"]))
        XCTAssertFalse(tags.contains { $0[0] == "endsAt" })
        let ids = tags.filter { $0[0] == "option" }.map { $0[1] }
        XCTAssertEqual(Set(ids).count, 2)
        XCTAssertTrue(ids.allSatisfy { $0.count == 9 && $0.allSatisfy { $0.isLetter || $0.isNumber } })
    }

    func testStatusFilter() {
        let open = NIP88Poll.Poll(id: "a", pubkey: "b", kind: 1068, content: "q",
                                  tags: [["option", "1", "A"], ["endsAt", "1800000100"]])!
        let closed = NIP88Poll.Poll(id: "a", pubkey: "b", kind: 1068, content: "q",
                                    tags: [["option", "1", "A"], ["endsAt", "1799999900"]])!
        let forever = NIP88Poll.Poll(id: "a", pubkey: "b", kind: 1068, content: "q", tags: [["option", "1", "A"]])!
        XCTAssertEqual([open, closed, forever].map { PollStatusFilter.open.admits($0, now: now) }, [true, false, true])
        XCTAssertEqual([open, closed, forever].map { PollStatusFilter.closed.admits($0, now: now) }, [false, true, false])
        XCTAssertEqual([open, closed, forever].map { PollStatusFilter.all.admits($0, now: now) }, [true, true, true])
    }
}
