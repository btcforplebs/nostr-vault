import XCTest
@testable import MediaLogic

/// The Music tab's Wavlake cache: what it asks Wavlake, and when.
final class WavlakeCacheTests: XCTestCase {
    /// Counts requests per address and answers each with its number, so a
    /// test can tell a kept answer from a new one.
    private actor FakeWavlake {
        var asked: [URL] = []
        var fails = false
        var delay: UInt64 = 0
        func answer(_ url: URL) async throws -> Data {
            asked.append(url)
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            if fails { throw URLError(.notConnectedToInternet) }
            return Data("\(asked.count)".utf8)
        }
        func setFails(_ value: Bool) { fails = value }
        func setDelay(_ value: UInt64) { delay = value }
    }

    private final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    private let url = URL(string: "https://wavlake.com/api/v1/content/rankings?sort=sats&days=7")!
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WavlakeCacheTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeCache(_ fake: FakeWavlake, _ clock: Clock, onDisk: Bool = true) -> WavlakeCache {
        WavlakeCache(directory: onDisk ? directory : nil, now: { clock.now }, loader: { try await fake.answer($0) })
    }

    private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    func testFreshAnswerIsNotAskedForAgain() async throws {
        let fake = FakeWavlake(), clock = Clock()
        let cache = makeCache(fake, clock)
        _ = try await cache.data(url, maxAge: 600)
        clock.now += 599
        let again = try await cache.data(url, maxAge: 600)
        XCTAssertEqual(text(again), "1")
        let asked = await fake.asked.count
        XCTAssertEqual(asked, 1)
    }

    func testStaleAnswerIsAskedForAgain() async throws {
        let fake = FakeWavlake(), clock = Clock()
        let cache = makeCache(fake, clock)
        _ = try await cache.data(url, maxAge: 600)
        clock.now += 600
        let stale = await cache.stored(url)
        XCTAssertEqual(stale.map { text($0.data) }, "1", "a stale answer is still there to show")
        let again = try await cache.data(url, maxAge: 600)
        XCTAssertEqual(text(again), "2")
    }

    func testSameAddressAtOnceIsOneRequest() async throws {
        let fake = FakeWavlake(), clock = Clock()
        await fake.setDelay(50_000_000)
        let cache = makeCache(fake, clock)
        async let a = cache.data(url, maxAge: 600)
        async let b = cache.data(url, maxAge: 600)
        async let c = cache.load(url)
        let answers = try await [a, b, c].map(text)
        XCTAssertEqual(answers, ["1", "1", "1"])
        let asked = await fake.asked.count
        XCTAssertEqual(asked, 1)
    }

    func testRelaunchReadsTheDiskWithItsAge() async throws {
        let fake = FakeWavlake(), clock = Clock()
        _ = try await makeCache(fake, clock).data(url, maxAge: 600)

        let relaunched = makeCache(fake, clock)
        clock.now += 300
        let kept = try await relaunched.data(url, maxAge: 600)
        XCTAssertEqual(text(kept), "1")
        clock.now += 300
        let stored = await relaunched.stored(url)
        let hit = try XCTUnwrap(stored)
        let fresh = await relaunched.isFresh(hit, maxAge: 600)
        XCTAssertFalse(fresh, "the file's date carries the answer's age")
        let asked = await fake.asked.count
        XCTAssertEqual(asked, 1)
    }

    func testMemoryOnlyCacheWritesNothing() async throws {
        let fake = FakeWavlake(), clock = Clock()
        _ = try await makeCache(fake, clock, onDisk: false).data(url, maxAge: 600)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        _ = try await makeCache(fake, clock, onDisk: false).data(url, maxAge: 600)
        let asked = await fake.asked.count
        XCTAssertEqual(asked, 2)
    }

    func testFailureKeepsTheOldAnswer() async throws {
        let fake = FakeWavlake(), clock = Clock()
        let cache = makeCache(fake, clock)
        _ = try await cache.data(url, maxAge: 600)
        clock.now += 601
        await fake.setFails(true)
        do {
            _ = try await cache.data(url, maxAge: 600)
            XCTFail("a failed request throws")
        } catch {}
        let kept = await cache.stored(url)
        XCTAssertEqual(kept.map { text($0.data) }, "1")
        // And the failure isn't remembered: the next ask goes out again.
        await fake.setFails(false)
        let again = try await cache.data(url, maxAge: 600)
        XCTAssertEqual(text(again), "3")
    }

    func testAddressesAreKeptApart() async throws {
        let fake = FakeWavlake(), clock = Clock()
        let cache = makeCache(fake, clock)
        let other = URL(string: "https://wavlake.com/api/v1/content/rankings?sort=sats&days=30")!
        _ = try await cache.data(url, maxAge: 600)
        let second = try await cache.data(other, maxAge: 600)
        XCTAssertEqual(text(second), "2")
        let first = try await makeCache(fake, clock).data(url, maxAge: 600)
        XCTAssertEqual(text(first), "1")
    }
}
