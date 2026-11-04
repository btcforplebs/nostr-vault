import XCTest
@testable import MediaLogic

final class NVLiveNowLogicTests: XCTestCase {
    private let host = String(repeating: "a", count: 64)
    private let signer = String(repeating: "b", count: 64)

    func testSmallDrawsOneMediumThree() {
        XCTAssertEqual(NVLiveNowLogic.rows(isSmall: true), 1)
        XCTAssertEqual(NVLiveNowLogic.rows(isSmall: false), 3)
    }

    func testLinkRoundTripsAndKeepsOnlyTheHostParticipant() throws {
        let tags = [["d", "stream-1"], ["title", "Late night + beats / all request"],
                    ["streaming", "https://example.com/live.m3u8"],
                    ["p", host, "", "Host"], ["p", "c", "", "Participant"], ["p", "d"]]
        let url = try XCTUnwrap(NVLiveLink.url(id: "e1", pubkey: signer, createdAt: 1_762_000_000, tags: tags))
        XCTAssertEqual(url.scheme, "nostrvault")
        XCTAssertEqual(url.host, "live")
        let event = try XCTUnwrap(NVLiveLink.parse(url))
        XCTAssertEqual(event.id, "e1")
        XCTAssertEqual(event.pubkey, signer)
        XCTAssertEqual(event.createdAt, 1_762_000_000)
        XCTAssertEqual(event.tags, [["d", "stream-1"], ["title", "Late night + beats / all request"],
                                    ["streaming", "https://example.com/live.m3u8"], ["p", host, "", "Host"]])
        // The host the app plays as is the one the widget showed.
        XCTAssertEqual(LiveChat.hostPubkey(authorPubkey: event.pubkey, tags: event.tags), host)
    }

    func testParseRefusesOtherLinksAndGarbage() {
        XCTAssertNil(NVLiveLink.parse(URL(string: "nostrvault://feed")!))
        XCTAssertNil(NVLiveLink.parse(URL(string: "nostrvault://live")!))
        XCTAssertNil(NVLiveLink.parse(URL(string: "nostrvault://live?e=not-base64!!")!))
        XCTAssertNil(NVLiveLink.parse(URL(string: "https://live?e=e30")!))
        // Valid base64 of "{}": decodes, but carries no event.
        XCTAssertNil(NVLiveLink.parse(URL(string: "nostrvault://live?e=e30")!))
    }

    func testOnlyRelaysTheWidgetCanReachAreAsked() {
        let urls = NVLiveNowLogic.askableRelays([
            "wss://relay.zap.stream", " wss://relay.damus.io ", "wss://relay.zap.stream",
            "ws://127.0.0.1:3355", "ws://localhost:3355", "wss://npub1x.fips", "https://example.com", "",
        ])
        XCTAssertEqual(urls.map(\.absoluteString), ["wss://relay.zap.stream", "wss://relay.damus.io"])
    }

    func testFiltersAskByAuthorAndHostInChunks() {
        let follows = (0..<301).map { String(format: "%064x", $0) }
        let filters = NVLiveNowLogic.streamFilters(follows: follows)
        XCTAssertEqual(filters.count, 6)
        XCTAssertEqual((filters[0]["authors"] as? [String])?.count, 150)
        XCTAssertEqual((filters[1]["#p"] as? [String])?.count, 150)
        XCTAssertEqual((filters[5]["#p"] as? [String]), [follows[300]])
        XCTAssertTrue(filters.allSatisfy { $0["kinds"] as? [Int] == [30311] })
        XCTAssertTrue(NVLiveNowLogic.streamFilters(follows: []).isEmpty)
    }

    func testProfilePrefersDisplayNameAndRefusesOddPictureSchemes() {
        let full = NVLiveNowLogic.profile(fromContent: #"{"name":"nogood","display_name":"NoGood Radio","picture":"https://x.com/a.jpg"}"#)
        XCTAssertEqual(full.name, "NoGood Radio")
        XCTAssertEqual(full.picture?.absoluteString, "https://x.com/a.jpg")
        let nameOnly = NVLiveNowLogic.profile(fromContent: #"{"name":"nogood","display_name":"  ","picture":"javascript:alert(1)"}"#)
        XCTAssertEqual(nameOnly.name, "nogood")
        XCTAssertNil(nameOnly.picture)
        XCTAssertNil(NVLiveNowLogic.profile(fromContent: "not json").name)
    }

    func testHandoffOlderThanTheFieldsStillMeansNeverRun() {
        XCTAssertEqual(NVLiveHandoff.empty.generatedAt, .distantPast)
        XCTAssertTrue(NVLiveHandoff.empty.follows.isEmpty)
        XCTAssertFalse(NVLiveHandoff.empty.followListIsKnown)
    }
}
