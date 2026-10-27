import XCTest
@testable import MediaLogic

final class LiveStatusBookTests: XCTestCase {
    private let host = String(repeating: "a", count: 64)
    private let service = String(repeating: "b", count: 64)
    private let guest = String(repeating: "c", count: 64)
    private let now: Int64 = 1_800_000_000
    private let hls = ["streaming", "https://cdn.example/live/index.m3u8"]

    private func event(_ id: String, by pubkey: String, d: String = "s1", at createdAt: Int64,
                       _ extra: [[String]]) -> LiveStatusBook.Event {
        LiveStatusBook.Event(id: id, pubkey: pubkey, createdAt: createdAt, tags: [["d", d]] + extra)
    }

    func testLiveHostGetsTheRing() {
        var book = LiveStatusBook()
        book.ingest(event("e1", by: host, at: now - 60, [["status", "live"], hls]))
        XCTAssertEqual(book.liveEvent(hostedBy: host, at: now)?.id, "e1")
        XCTAssertEqual(book.liveHosts(at: now), [host])
    }

    func testServicePublishedStreamRingsTheHostNotTheService() {
        var book = LiveStatusBook()
        book.ingest(event("e1", by: service, at: now - 60,
                          [["status", "live"], hls, ["p", host, "", "Host"], ["p", guest, "", "Speaker"]]))
        XCTAssertNotNil(book.liveEvent(hostedBy: host, at: now))
        XCTAssertNil(book.liveEvent(hostedBy: service, at: now))
        XCTAssertNil(book.liveEvent(hostedBy: guest, at: now), "a guest is not the one streaming")
    }

    func testEndedStaleOrUnplayableStreamsGetNoRing() {
        var book = LiveStatusBook()
        book.ingest(event("ended", by: host, d: "a", at: now - 60, [["status", "ended"], hls]))
        book.ingest(event("stale", by: host, d: "b", at: now - 2 * 3600, [["status", "live"], hls]))
        book.ingest(event("noURL", by: host, d: "c", at: now - 60, [["status", "live"]]))
        book.ingest(event("web", by: host, d: "d", at: now - 60,
                          [["status", "live"], ["streaming", "https://youtube.com/live/x"]]))
        book.ingest(event("pastEnds", by: host, d: "e", at: now - 60,
                          [["status", "live"], hls, ["ends", String(now - 1)]]))
        XCTAssertNil(book.liveEvent(hostedBy: host, at: now))
        XCTAssertTrue(book.liveHosts(at: now).isEmpty)
    }

    func testNewerEndedEventReplacesTheLiveOne() {
        var book = LiveStatusBook()
        book.ingest(event("live", by: host, at: now - 120, [["status", "live"], hls]))
        XCTAssertTrue(book.ingest(event("end", by: host, at: now - 30, [["status", "ended"], hls])))
        XCTAssertFalse(book.ingest(event("old", by: host, at: now - 300, [["status", "live"], hls])),
                       "an older copy from a slower relay must not bring the ring back")
        XCTAssertNil(book.liveEvent(hostedBy: host, at: now))
    }

    func testNewestOfTwoLiveStreamsIsTheOneOpened() {
        var book = LiveStatusBook()
        book.ingest(event("first", by: host, d: "a", at: now - 600, [["status", "live"], hls]))
        book.ingest(event("second", by: host, d: "b", at: now - 60, [["status", "live"], hls]))
        XCTAssertEqual(book.liveEvent(hostedBy: host, at: now)?.id, "second")
    }

    func testPubkeysAreAskedAgainOnlyAfterTheRecheckWindow() {
        var book = LiveStatusBook()
        let t0 = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(book.takeDue([host, guest], now: t0), [host, guest].sorted())
        XCTAssertEqual(book.takeDue([host, service], now: t0.addingTimeInterval(10)), [service])
        XCTAssertEqual(book.takeDue([host], now: t0.addingTimeInterval(LiveStatusBook.recheckAfter)), [host])
        book.reset()
        XCTAssertEqual(book.takeDue([guest], now: t0.addingTimeInterval(11)), [guest])
    }
}
