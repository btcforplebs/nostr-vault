import XCTest
@testable import MediaLogic

/// NIP-88 polls: read from a kind 1068, counted from kind 1018 votes with one
/// vote per person, only real options, nothing after the poll closes.
final class NIP88PollTests: XCTestCase {
    private let pollId = String(repeating: "a", count: 64)
    private let author = String(repeating: "b", count: 64)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func poll(type: String? = nil, endsAt: Double? = nil, relays: [String] = []) -> NIP88Poll.Poll {
        var tags: [[String]] = [["option", "yes", "Yes"], ["option", "no", "No"], ["option", "idk", "Not sure"]]
        if let type { tags.append(["polltype", type]) }
        if let endsAt { tags.append(["endsAt", String(Int(endsAt))]) }
        tags += relays.map { ["relay", $0] }
        return NIP88Poll.Poll(id: pollId, pubkey: author, kind: 1068, content: " Ship it? ", tags: tags)!
    }

    private func vote(_ voter: Character, _ picks: [String], at offset: Double = -60,
                      id: String? = nil, pollRef: String? = nil, kind: Int = 1018) -> [String: Any] {
        var tags: [[String]] = [["e", pollRef ?? pollId]]
        tags += picks.map { ["response", $0] }
        return ["id": id ?? UUID().uuidString, "pubkey": String(repeating: voter, count: 64), "kind": kind,
                "content": "", "created_at": now.timeIntervalSince1970 + offset, "tags": tags, "sig": ""]
    }

    // MARK: Reading a poll

    func testReadsQuestionOptionsTypeEndAndRelays() {
        let p = poll(type: "multiplechoice", endsAt: 1_900_000_000, relays: ["wss://relay.one"])
        XCTAssertEqual(p.question, "Ship it?")
        XCTAssertEqual(p.options.map(\.id), ["yes", "no", "idk"])
        XCTAssertEqual(p.options.map(\.label), ["Yes", "No", "Not sure"])
        XCTAssertEqual(p.type, .multiple)
        XCTAssertEqual(p.endsAt, Date(timeIntervalSince1970: 1_900_000_000))
        XCTAssertEqual(p.relays, ["wss://relay.one"])
    }

    func testDefaultsToSingleChoiceAndNoEnd() {
        let p = poll()
        XCTAssertEqual(p.type, .single)
        XCTAssertNil(p.endsAt)
        XCTAssertFalse(p.isClosed(now: now))
    }

    func testRejectsOtherKindsAndPollsWithoutOptions() {
        XCTAssertNil(NIP88Poll.Poll(id: pollId, pubkey: author, kind: 1, content: "q", tags: [["option", "a", "A"]]))
        XCTAssertNil(NIP88Poll.Poll(id: pollId, pubkey: author, kind: 1068, content: "q", tags: [["option", "a", " "]]))
    }

    func testDuplicateOptionIdsKeepTheFirst() {
        let p = NIP88Poll.Poll(id: pollId, pubkey: author, kind: 1068, content: "q",
                               tags: [["option", "a", "First"], ["option", "a", "Second"]])
        XCTAssertEqual(p?.options, [NIP88Poll.Option(id: "a", label: "First")])
    }

    func testClosedOnceEndsAtPasses() {
        XCTAssertTrue(poll(endsAt: now.timeIntervalSince1970 - 1).isClosed(now: now))
        XCTAssertFalse(poll(endsAt: now.timeIntervalSince1970 + 60).isClosed(now: now))
    }

    // MARK: Counting

    func testCountsOneVotePerPersonNewestWins() {
        let t = NIP88Poll.tally([vote("c", ["yes"], at: -300), vote("c", ["no"], at: -10), vote("d", ["no"])],
                                poll: poll(), now: now)
        XCTAssertEqual(t.voters.count, 2)
        XCTAssertEqual(t.count("yes"), 0)
        XCTAssertEqual(t.count("no"), 2)
        XCTAssertEqual(t.share("no"), 1)
    }

    func testSameSecondTieIsDecidedTheSameWayEverywhere() {
        let a = vote("c", ["yes"], at: -10, id: "1")
        let b = vote("c", ["no"], at: -10, id: "2")
        XCTAssertEqual(NIP88Poll.tally([a, b], poll: poll(), now: now).picksByVoter.values.first, ["yes"])
        XCTAssertEqual(NIP88Poll.tally([b, a], poll: poll(), now: now).picksByVoter.values.first, ["yes"])
    }

    func testSingleChoiceCountsOnlyTheFirstPick() {
        let t = NIP88Poll.tally([vote("c", ["no", "yes"])], poll: poll(), now: now)
        XCTAssertEqual(t.count("no"), 1)
        XCTAssertEqual(t.count("yes"), 0)
    }

    func testMultipleChoiceCountsEachPickOnce() {
        let t = NIP88Poll.tally([vote("c", ["no", "yes", "no"]), vote("d", ["yes"])],
                                poll: poll(type: "multiplechoice"), now: now)
        XCTAssertEqual(t.voters.count, 2)
        XCTAssertEqual(t.count("yes"), 2)
        XCTAssertEqual(t.count("no"), 1)
        XCTAssertEqual(t.share("no"), 0.5)
    }

    func testIgnoresUnknownOptionsOtherPollsAndOtherKinds() {
        let t = NIP88Poll.tally([vote("c", ["maybe"]),
                                 vote("d", ["yes"], pollRef: String(repeating: "f", count: 64)),
                                 vote("e", ["yes"], kind: 7)],
                                poll: poll(), now: now)
        XCTAssertTrue(t.voters.isEmpty)
    }

    func testANewerVoteWithNoRealPicksWithdrawsTheEarlierOne() {
        // Newest wins, and the newest said nothing countable: that person
        // has withdrawn, as other clients count it.
        let t = NIP88Poll.tally([vote("c", ["yes"], at: -300), vote("c", ["maybe"], at: -10)], poll: poll(), now: now)
        XCTAssertTrue(t.voters.isEmpty)
    }

    func testVotesAfterThePollClosesDoNotCount() {
        let p = poll(endsAt: now.timeIntervalSince1970 - 100)
        let t = NIP88Poll.tally([vote("c", ["yes"], at: -200), vote("c", ["no"], at: -50), vote("d", ["no"], at: -50)],
                                poll: p, now: now)
        XCTAssertEqual(t.voters.count, 1)
        XCTAssertEqual(t.picksByVoter[String(repeating: "c", count: 64)], ["yes"])
    }

    func testFutureDatedVotesDoNotPinAPick() {
        let t = NIP88Poll.tally([vote("c", ["yes"], at: -60), vote("c", ["no"], at: 86_400)], poll: poll(), now: now)
        XCTAssertEqual(t.picksByVoter[String(repeating: "c", count: 64)], ["yes"])
    }

    // MARK: Voting

    func testVoteTagsNameThePollAndOnlyRealPicks() {
        let tags = NIP88Poll.responseTags(poll: poll(), optionIds: ["no", "yes", "bogus"], relayHint: "wss://r")
        XCTAssertEqual(tags, [["e", pollId, "wss://r"], ["p", author], ["response", "no"]])
        let multi = NIP88Poll.responseTags(poll: poll(type: "multiplechoice"), optionIds: ["no", "yes", "no"], relayHint: "")
        XCTAssertEqual(multi.filter { $0[0] == "response" }, [["response", "no"], ["response", "yes"]])
    }

    func testFilterAsksForVotesOnThisPoll() {
        let f = NIP88Poll.responseFilters(pollId: pollId)
        XCTAssertEqual(f.first?["kinds"] as? [Int], [1018])
        XCTAssertEqual(f.first?["#e"] as? [String], [pollId])
    }

    func testRelaysPutThePollsOwnFirstAndDropDuplicates() {
        let p = poll(relays: ["wss://poll.relay/", "https://not-a-relay"])
        let r = NIP88Poll.relays(poll: p, fallback: ["wss://poll.relay", "wss://feed.relay"])
        XCTAssertEqual(r, ["wss://poll.relay/", "wss://feed.relay"])
    }

    func testRelaysDropAStrangersPrivateAddresses() {
        let lan = ["ws://192.168.1.5:4848", "wss://192.168.1.5", "wss://umbrel.local", "ws://localhost:7777",
                   "wss://127.0.0.1", "wss://10.0.0.2", "wss://172.20.0.3", "wss://abc.onion", "wss://169.254.1.1"]
        let p = poll(relays: lan + ["wss://poll.relay"])
        let r = NIP88Poll.relays(poll: p, fallback: ["ws://127.0.0.1:4869"],
                                 outbox: ["wss://nas.local", "wss://outbox.relay"])
        // This device's own relay stays; the stranger's private ones go.
        XCTAssertEqual(r, ["wss://poll.relay", "ws://127.0.0.1:4869", "wss://outbox.relay"])
    }
}
