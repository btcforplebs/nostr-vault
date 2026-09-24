import XCTest
@testable import MediaLogic

final class GlobalSearchLogicTests: XCTestCase {

    // MARK: Relay list

    func testDefaultsAreTheProbedServicesAndDropTheDeadOnes() {
        XCTAssertEqual(SearchRelayDefaults.relays, [
            "wss://nostr.wine",
            "wss://search.nos.today",
            "wss://relay.vertexlab.io",
            "wss://profiles.nostrver.se"
        ])
        XCTAssertFalse(SearchRelayDefaults.relays.contains { $0.contains("nostr.band") })
        XCTAssertFalse(SearchRelayDefaults.relays.contains { $0.contains("noswhere") })
    }

    func testNeverStoredMeansDefaultsButStoredEmptyIsHonoured() {
        XCTAssertEqual(SearchRelayDefaults.effective(stored: nil), SearchRelayDefaults.relays)
        XCTAssertEqual(SearchRelayDefaults.effective(stored: []), [])
    }

    func testNormalizedDropsBlanksAndDuplicates() {
        let out = SearchRelayDefaults.normalized([" wss://a.example ", "", "WSS://A.example/", "wss://b.example"])
        XCTAssertEqual(out, ["wss://a.example", "wss://b.example"])
    }

    // MARK: Term matching

    func testAllTermsMustMatchInAnyOrderCaseInsensitive() throws {
        let m = try XCTUnwrap(SearchTermMatcher(query: "Bitcoin  BEACH"))
        XCTAssertTrue(m.matches("A day at the beach talking bitcoin"))
        XCTAssertFalse(m.matches("bitcoin only"))
        XCTAssertFalse(m.matches("beach only"))
    }

    func testProfileTermsMaySpanFields() throws {
        let m = try XCTUnwrap(SearchTermMatcher(query: "jane doe"))
        XCTAssertTrue(m.matches(fields: ["jane", nil, "doe@example.com"]))
        XCTAssertFalse(m.matches(fields: ["jane", nil, nil]))
    }

    func testTooShortQueryHasNoMatcher() {
        XCTAssertNil(SearchTermMatcher(query: " a "))
    }

    /// Relay mode keeps its whole-phrase match; only the Global own-store
    /// matcher is all-terms.
    func testLocalMatcherModes() throws {
        let phrase = try XCTUnwrap(LocalSearchMatcher(query: "bitcoin beach"))
        XCTAssertFalse(phrase.matchesNote(content: "beach day, bitcoin night"))
        XCTAssertTrue(phrase.matchesNote(content: "the Bitcoin Beach meetup"))

        let terms = try XCTUnwrap(LocalSearchMatcher(allTermsOf: "bitcoin beach"))
        XCTAssertTrue(terms.matchesNote(content: "beach day, bitcoin night"))
        XCTAssertFalse(terms.matchesNote(content: "bitcoin night"))
        XCTAssertTrue(terms.matchesProfile(displayName: "Bitcoin Beach", name: nil, about: nil,
                                           nip05: nil, pubkey: "abc"))
    }

    // MARK: Ranking

    private struct N { let id: String; let pubkey: String; let t: Double }

    func testOwnThenFollowsThenEveryoneNewestFirstWithinTier() {
        let notes = [
            N(id: "1", pubkey: "stranger", t: 500),
            N(id: "2", pubkey: "friend", t: 100),
            N(id: "3", pubkey: "me", t: 10),
            N(id: "4", pubkey: "friend", t: 200),
            N(id: "5", pubkey: "me", t: 20),
        ]
        let ranked = GlobalSearchRanking.rankNotes(notes, own: ["me"], follows: ["friend"],
                                                   pubkey: { $0.pubkey },
                                                   createdAt: { Date(timeIntervalSince1970: $0.t) },
                                                   id: { $0.id })
        XCTAssertEqual(ranked.map(\.id), ["5", "3", "4", "2", "1"])
    }

    func testProfilesKeepArrivalOrderWithinTier() {
        let ranked = GlobalSearchRanking.rankProfiles(["x", "friend", "y", "me"],
                                                      own: ["me"], follows: ["friend"])
        XCTAssertEqual(ranked, ["me", "friend", "x", "y"])
    }

    // MARK: Source status

    func testProfileOnlyRelayThatClosesNotesStillAnswers() {
        var p = GlobalSearchSourceProgress(pending: 2)
        p.closed(reason: "we support only kind:0 search queries")
        XCTAssertEqual(p.state, .searching)
        p.event(counted: true)
        p.eose()
        XCTAssertEqual(p.state, .found(1))
    }

    func testBothReqsClosedIsNoAnswerWithReason() {
        var p = GlobalSearchSourceProgress(pending: 2)
        p.closed(reason: "auth-required: no")
        p.closed(reason: "auth-required: no")
        XCTAssertEqual(p.state, .noAnswer("auth-required: no"))
    }

    func testEoseWithNothingIsZeroFoundNotNoAnswer() {
        var p = GlobalSearchSourceProgress(pending: 2)
        p.eose(); p.eose()
        XCTAssertEqual(p.state, .found(0))
    }

    func testTimeoutWithoutAnswerIsNoAnswer() {
        var p = GlobalSearchSourceProgress(pending: 2)
        p.timeout()
        XCTAssertEqual(p.state, .noAnswer("timed out"))
    }

    func testTimeoutAfterSomeEventsKeepsTheCount() {
        var p = GlobalSearchSourceProgress(pending: 2)
        p.event(counted: true); p.event(counted: true); p.event(counted: false)
        p.timeout()
        XCTAssertEqual(p.state, .found(2))
    }

    /// A paged walk (phone store, Mac without NIP-50) that returned pages but
    /// was cut off by the cap has answered — it reports what it found. Seen
    /// live: 22 matches shown as "no answer: timed out".
    func testPagedWalkCutOffByCapStillCountsAsAnswered() {
        var p = GlobalSearchSourceProgress(pending: 1)
        p.markAnswered()
        p.setResults(22)
        p.timeout()
        XCTAssertEqual(p.state, .found(22))
    }

    /// Cached profiles alone do not make an unreachable store look answered.
    func testResultCountAloneIsNotAnAnswer() {
        var p = GlobalSearchSourceProgress(pending: 1)
        p.setResults(3)
        p.failed(reason: "could not connect", openReqs: 1)
        XCTAssertEqual(p.state, .noAnswer("could not connect"))
    }

    func testSocketFailureEndsAllItsReqs() {
        var p = GlobalSearchSourceProgress(pending: 6)
        p.failed(reason: "could not connect", openReqs: 2)
        p.eose(); p.eose(); p.eose(); p.eose()
        XCTAssertEqual(p.state, .found(0))
    }

    /// The Mac probe's pending unit is swapped for real subscriptions.
    func testProbeResolveHandsOverToSubscriptions() {
        var p = GlobalSearchSourceProgress(pending: 1)
        p.addPending(2)
        p.resolve()
        XCTAssertEqual(p.state, .searching)
        p.eose(); p.eose()
        XCTAssertEqual(p.state, .found(0))
    }

    // MARK: NIP-11

    func testInfoURLMapsWebsocketSchemes() {
        XCTAssertEqual(RelayInfoDocument.url(forRelay: URL(string: "wss://mac.example.com")!)?.absoluteString,
                       "https://mac.example.com/")
        XCTAssertEqual(RelayInfoDocument.url(forRelay: URL(string: "ws://10.0.0.2:3355")!)?.absoluteString,
                       "http://10.0.0.2:3355/")
        XCTAssertNil(RelayInfoDocument.url(forRelay: URL(string: "ftp://x")!))
    }

    func testSupportsNIP50() {
        XCTAssertTrue(RelayInfoDocument.supportsNIP50(Data(#"{"supported_nips":[1,11,50]}"#.utf8)))
        XCTAssertTrue(RelayInfoDocument.supportsNIP50(Data(#"{"supported_nips":["50"]}"#.utf8)))
        XCTAssertFalse(RelayInfoDocument.supportsNIP50(Data(#"{"supported_nips":[1,11,42]}"#.utf8)))
        XCTAssertFalse(RelayInfoDocument.supportsNIP50(Data(#"{}"#.utf8)))
        XCTAssertFalse(RelayInfoDocument.supportsNIP50(Data("<html>".utf8)))
    }

    // MARK: Merge

    func testMergeDedupesByIdAndPubkeyFirstWins() {
        var m = GlobalSearchMerge<String, String>()
        XCTAssertTrue(m.add(note: "a-from-wine", id: "a"))
        XCTAssertFalse(m.add(note: "a-from-nos", id: "a"))
        XCTAssertTrue(m.add(profile: "p1", pubkey: "k1"))
        XCTAssertTrue(m.add(profile: "p2", pubkey: "k2"))
        XCTAssertFalse(m.add(profile: "p1-again", pubkey: "k1"))
        XCTAssertEqual(m.notes["a"], "a-from-wine")
        XCTAssertEqual(m.profileOrder, ["k1", "k2"])
        XCTAssertEqual(m.profiles["k1"], "p1")
    }
}
