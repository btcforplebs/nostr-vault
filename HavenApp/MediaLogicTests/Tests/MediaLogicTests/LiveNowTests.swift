import XCTest
@testable import MediaLogic

final class LiveNowTests: XCTestCase {
    private let friend = String(repeating: "a", count: 64)
    private let service = String(repeating: "b", count: 64)
    private let stranger = String(repeating: "c", count: 64)
    private let other = String(repeating: "d", count: 64)
    private let now: Int64 = 1_800_000_000
    private let hls = ["streaming", "https://cdn.example/live/index.m3u8"]

    private func event(_ id: String, by pubkey: String, d: String = "s1", at createdAt: Int64,
                       _ extra: [[String]]) -> LiveStatusBook.Event {
        LiveStatusBook.Event(id: id, pubkey: pubkey, createdAt: createdAt, tags: [["d", d]] + extra)
    }

    private func ids(_ events: [LiveStatusBook.Event], follows: Set<String>? = nil,
                     blocked: Set<String> = []) -> [String] {
        LiveNow.pick(events, follows: follows ?? [friend, other], blocked: blocked, now: now).map(\.id)
    }

    func testLiveStreamsOfFollowsNewestFirst() {
        let events = [
            event("old", by: friend, d: "a", at: now - 600, [["status", "live"], hls]),
            event("new", by: other, d: "b", at: now - 60, [["status", "live"], hls]),
        ]
        XCTAssertEqual(ids(events), ["new", "old"])
    }

    func testStrangersAndFollowedGuestsAreLeftOut() {
        let events = [
            event("stranger", by: stranger, at: now - 60, [["status", "live"], hls]),
            event("guest", by: stranger, d: "g", at: now - 60,
                  [["status", "live"], hls, ["p", friend, "", "Speaker"]]),
        ]
        XCTAssertEqual(ids(events), [])
    }

    func testServicePublishedStreamCountsForTheHost() {
        let events = [event("svc", by: service, at: now - 60, [["status", "live"], hls, ["p", friend, "", "Host"]])]
        XCTAssertEqual(ids(events), ["svc"])
        XCTAssertEqual(ids(events, blocked: [friend]), [], "a block on the host reaches service-published streams")
        XCTAssertEqual(ids(events, blocked: [service]), [], "a block on the signer hides it too")
    }

    func testEndedReplacesItsOwnLiveAnnouncement() {
        let events = [
            event("ended", by: friend, at: now - 30, [["status", "ended"], hls]),
            event("live", by: friend, at: now - 300, [["status", "live"], hls]),
        ]
        XCTAssertEqual(ids(events), [])
        XCTAssertEqual(ids(events.reversed()), [], "order of arrival doesn't matter")
    }

    func testStaleUnplayableAndPastEndsAreNotLive() {
        let events = [
            event("stale", by: friend, d: "a", at: now - 2 * 3600, [["status", "live"], hls]),
            event("noURL", by: friend, d: "b", at: now - 60, [["status", "live"]]),
            event("web", by: friend, d: "c", at: now - 60, [["status", "live"], ["streaming", "https://youtube.com/live/x"]]),
            event("pastEnds", by: friend, d: "e", at: now - 60, [["status", "live"], hls, ["ends", String(now - 1)]]),
            event("planned", by: friend, d: "f", at: now - 60, [["status", "planned"], hls]),
        ]
        XCTAssertEqual(ids(events), [])
    }

    func testNoFollowsNoRows() {
        let events = [event("e", by: friend, at: now - 60, [["status", "live"], hls])]
        XCTAssertEqual(ids(events, follows: []), [])
    }

    func testEmptyLines() {
        XCTAssertEqual(LiveNow.emptyLine(followsSomeone: true), "Nobody you follow is live right now.")
        XCTAssertEqual(LiveNow.emptyLine(followsSomeone: false), "Follow people to see when they go live.")
    }

    func testPanelIdMatchesTheWeb() {
        XCTAssertEqual(LiveNow.panelId, "live-now")
    }
}
