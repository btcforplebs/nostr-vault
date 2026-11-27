import XCTest
@testable import MediaLogic

final class MediaSizeCacheTests: XCTestCase {
    private let sha = String(repeating: "ab", count: 32)

    func testOnlyAPlain200WithALengthGivesASize() {
        XCTAssertEqual(MediaSizeCache.size(status: 200, contentLength: "2457600"), 2_457_600)
        XCTAssertEqual(MediaSizeCache.size(status: 200, contentLength: " 12 "), 12)
        // A range answer is the length of the range, not the file.
        XCTAssertNil(MediaSizeCache.size(status: 206, contentLength: "1"))
        XCTAssertNil(MediaSizeCache.size(status: 404, contentLength: "153"))
        XCTAssertNil(MediaSizeCache.size(status: 200, contentLength: nil))
        XCTAssertNil(MediaSizeCache.size(status: 200, contentLength: "0"))
        XCTAssertNil(MediaSizeCache.size(status: 200, contentLength: "-5"))
        XCTAssertNil(MediaSizeCache.size(status: 200, contentLength: "12abc"))
    }

    func testStoresBySha256CaseInsensitively() {
        var cache = MediaSizeCache()
        cache.store(hash: sha.uppercased(), size: 42)
        XCTAssertEqual(cache.size(sha), 42)
        XCTAssertEqual(cache.size(sha.uppercased()), 42)
    }

    func testNeverStoresAnUnknownOrABadKey() {
        var cache = MediaSizeCache()
        cache.store(hash: sha, size: 0)
        cache.store(hash: "not-a-hash", size: 10)
        cache.store(hash: String(sha.dropLast()), size: 10)
        XCTAssertTrue(cache.entries.isEmpty)
    }

    func testPruneKeepsTheNewest() {
        var cache = MediaSizeCache()
        let base = Date(timeIntervalSince1970: 1_000)
        for i in 0..<(MediaSizeCache.maxEntries + 3) {
            let h = String(format: "%064x", i)
            cache.store(hash: h, size: Int64(i + 1), now: base.addingTimeInterval(Double(i)))
        }
        let pruned = cache.pruned()
        XCTAssertEqual(pruned.entries.count, MediaSizeCache.maxEntries)
        XCTAssertNil(pruned.size(String(format: "%064x", 0)))
        XCTAssertNotNil(pruned.size(String(format: "%064x", MediaSizeCache.maxEntries + 2)))
    }

    func testRoundTripsThroughJSON() throws {
        var cache = MediaSizeCache()
        cache.store(hash: sha, size: 7)
        let back = try JSONDecoder().decode(MediaSizeCache.self, from: JSONEncoder().encode(cache))
        XCTAssertEqual(back, cache)
    }
}
