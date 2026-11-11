import XCTest
@testable import MediaLogic

/// The DM cache used to be encoded and written on the main thread, all of
/// it, for every message, and decoded on main at launch.
final class DMCacheFileTests: XCTestCase {
    // MARK: Fixtures

    private func message(_ i: Int, conversation: Int) -> DMMessage {
        DMMessage(id: "m\(conversation)-\(i)", senderPubkey: "p\(conversation)",
                  content: "hello \(i)", timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(i)),
                  isFromMe: i % 2 == 0, isNIP04: i % 7 == 0)
    }

    /// 2,000 messages over 20 conversations, written the way the old
    /// `saveConversations` wrote it: `JSONEncoder().encode(conversations)`.
    private func legacyCache() throws -> (Data, [DMConversation]) {
        let conversations = (0..<20).map { c in
            DMConversation(id: "p\(c)", messages: (0..<100).map { message($0, conversation: c) },
                           unreadCount: c)
        }
        return (try JSONEncoder().encode(conversations), conversations)
    }

    private func ids(_ conversations: [DMConversation]) -> [String] {
        conversations.flatMap { $0.messages.map(\.id) }
    }

    // MARK: Loading an existing file

    func testAnExistingCacheLoadsWithNoMessageLost() throws {
        let (data, written) = try legacyCache()
        let loaded = try XCTUnwrap(DMCacheFile.decode(data))
        XCTAssertEqual(ids(loaded).count, 2_000)
        XCTAssertEqual(ids(loaded), ids(written))
        XCTAssertEqual(loaded.map(\.unreadCount), written.map(\.unreadCount))
        XCTAssertEqual(loaded.flatMap { $0.messages.map(\.content) },
                       written.flatMap { $0.messages.map(\.content) })
        XCTAssertEqual(loaded.flatMap { $0.messages.map(\.isNIP04) },
                       written.flatMap { $0.messages.map(\.isNIP04) })
    }

    /// Bytes from a build before `isNIP04` existed.
    func testACacheFromBeforeNIP04Loads() throws {
        let json = #"[{"id":"p1","unreadCount":2,"messages":[{"id":"a","senderPubkey":"p1","content":"hi","timestamp":721000000,"isFromMe":false}]}]"#
        let loaded = try XCTUnwrap(DMCacheFile.decode(Data(json.utf8)))
        XCTAssertEqual(loaded.first?.messages.first?.id, "a")
        XCTAssertEqual(loaded.first?.messages.first?.isNIP04, false)
        XCTAssertEqual(loaded.first?.unreadCount, 2)
    }

    func testRewritingAnExistingCacheKeepsEveryMessage() throws {
        let (data, written) = try legacyCache()
        let loaded = try XCTUnwrap(DMCacheFile.decode(data))
        let again = try XCTUnwrap(DMCacheFile.decode(try DMCacheFile.encode(loaded)))
        XCTAssertEqual(ids(again), ids(written))
    }

    func testAnUnreadableFileGivesNil() {
        XCTAssertNil(DMCacheFile.decode(Data("not json".utf8)))
    }

    // MARK: No cap

    /// Nothing re-fetches older DMs, so a message cut from the file is gone.
    func testALongConversationIsWrittenInFull() throws {
        let long = DMConversation(id: "p0", messages: (0..<2_500).map { message($0, conversation: 0) }, unreadCount: 0)
        let stored = try XCTUnwrap(DMCacheFile.decode(try DMCacheFile.encode([long])))
        XCTAssertEqual(stored[0].messages.count, 2_500)
        XCTAssertEqual(stored[0].messages.first?.id, "m0-0")
    }

    // MARK: Merging what arrived during the load

    func testArrivalsDuringTheLoadAreKept() {
        let cached = DMConversation(id: "p0", messages: [message(1, conversation: 0), message(3, conversation: 0)], unreadCount: 1)
        let live = [
            DMConversation(id: "p0", messages: [message(5, conversation: 0), message(3, conversation: 0)], unreadCount: 1),
            DMConversation(id: "new", messages: [message(9, conversation: 9)], unreadCount: 1),
        ]
        let merged = DMCacheFile.merge(loaded: [cached], live: live)
        XCTAssertEqual(merged.map(\.id), ["p0", "new"])
        XCTAssertEqual(merged[0].messages.map(\.id), ["m0-1", "m0-3", "m0-5"])
        XCTAssertEqual(merged[0].unreadCount, 2)
        XCTAssertEqual(merged[1].messages.map(\.id), ["m9-9"])
    }

    /// A read message the relay re-delivers before the cache applies is not
    /// new: it must not come back unread.
    func testARedeliveredCachedMessageStaysRead() {
        let cached = DMConversation(id: "p0", messages: [message(1, conversation: 0)], unreadCount: 0)
        let live = DMConversation(id: "p0", messages: [message(1, conversation: 0)], unreadCount: 1)
        let merged = DMCacheFile.merge(loaded: [cached], live: [live])
        XCTAssertEqual(merged[0].messages.map(\.id), ["m0-1"])
        XCTAssertEqual(merged[0].unreadCount, 0)
    }

    func testNothingLiveLeavesTheCacheAsLoaded() throws {
        let (data, written) = try legacyCache()
        let merged = DMCacheFile.merge(loaded: try XCTUnwrap(DMCacheFile.decode(data)), live: [])
        XCTAssertEqual(ids(merged), ids(written))
    }

    // MARK: The writer

    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var _writes: [(URL, Data, Bool)] = []
        var writes: [(URL, Data, Bool)] { lock.withLock { _writes } }
        func add(_ url: URL, _ data: Data) { lock.withLock { _writes.append((url, data, Thread.isMainThread)) } }
    }

    func testABurstOfSavesIsOneWriteOfTheNewestSnapshot() {
        let sink = Sink()
        let writer = DMCacheWriter(delay: 0.05) { data, url in sink.add(url, data) }
        let url = URL(fileURLWithPath: "/tmp/a.json")
        for i in 0..<50 { writer.schedule(url) { Data("\(i)".utf8) } }
        let done = expectation(description: "written")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { done.fulfill() }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(sink.writes.count, 1)
        XCTAssertEqual(sink.writes.first.map { String(decoding: $0.1, as: UTF8.self) }, "49")
    }

    func testWritesNeverRunOnTheMainThread() {
        let sink = Sink()
        let writer = DMCacheWriter(delay: 0.01) { data, url in sink.add(url, data) }
        XCTAssertTrue(Thread.isMainThread)
        writer.schedule(URL(fileURLWithPath: "/tmp/a.json")) { Data("x".utf8) }
        writer.schedule(URL(fileURLWithPath: "/tmp/b.json")) { Data("y".utf8) }
        let done = expectation(description: "written")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { done.fulfill() }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(sink.writes.count, 2)
        XCTAssertEqual(sink.writes.map(\.2), [false, false])
    }

    func testEachFileKeepsItsOwnSnapshot() {
        let sink = Sink()
        let writer = DMCacheWriter(delay: 10) { data, url in sink.add(url, data) }
        let a = URL(fileURLWithPath: "/tmp/a.json"), b = URL(fileURLWithPath: "/tmp/b.json")
        writer.schedule(a) { Data("a".utf8) }
        writer.schedule(b) { Data("b".utf8) }
        writer.flushAndWait()
        XCTAssertEqual(sink.writes.map(\.0), [a, b])
        XCTAssertEqual(sink.writes.map { String(decoding: $0.1, as: UTF8.self) }, ["a", "b"])
    }

    func testAReadQueuedAfterASaveSeesIt() {
        let sink = Sink()
        let writer = DMCacheWriter(delay: 10) { data, url in sink.add(url, data) }
        writer.schedule(URL(fileURLWithPath: "/tmp/a.json")) { Data("x".utf8) }
        let read = expectation(description: "read")
        writer.flushThen {
            XCTAssertEqual(sink.writes.count, 1)
            read.fulfill()
        }
        wait(for: [read], timeout: 2)
    }

    func testARealFileRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("dm_cache_test.json")
        let writer = DMCacheWriter(delay: 10) { data, url in
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PrivateFile.write(data, to: url)
        }
        let (_, written) = try legacyCache()
        writer.schedule(url) { try DMCacheFile.encode(written) }
        writer.flushAndWait()
        let loaded = try XCTUnwrap(DMCacheFile.decode(try Data(contentsOf: url)))
        XCTAssertEqual(ids(loaded), ids(written))
    }
}
