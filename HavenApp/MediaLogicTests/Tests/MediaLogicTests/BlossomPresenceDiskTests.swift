import XCTest
@testable import MediaLogic

/// The photo screen's server answers kept on disk for a day.
final class BlossomPresenceDiskTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testFreshForADayThenStale() {
        var disk = BlossomPresenceDisk()
        disk.store(hash: "a", servers: ["https://one": true, "https://two": false], now: start)
        XCTAssertTrue(disk.isFresh("a", now: start.addingTimeInterval(23 * 3600)))
        XCTAssertFalse(disk.isFresh("a", now: start.addingTimeInterval(25 * 3600)))
        XCTAssertFalse(disk.isFresh("b", now: start))
        XCTAssertEqual(disk.entries["a"]?.servers, ["https://one": "present", "https://two": "absent"])
    }

    func testAnUnreachableServerIsNotKept() {
        var disk = BlossomPresenceDisk()
        disk.store(hash: "a", servers: ["https://one": true], now: start)
        disk.store(hash: "a", servers: ["https://one": true, "https://down": nil], now: start)
        XCTAssertNil(disk.entries["a"])
    }

    func testPruneDropsOldAndKeepsNewest() {
        var disk = BlossomPresenceDisk()
        disk.store(hash: "old", servers: ["s": true], now: start)
        let later = start.addingTimeInterval(30 * 3600)
        for i in 0..<(BlossomPresenceDisk.maxEntries + 5) {
            disk.store(hash: "h\(i)", servers: ["s": true], now: later.addingTimeInterval(Double(i)))
        }
        let pruned = disk.pruned(now: later.addingTimeInterval(10_000))
        XCTAssertNil(pruned.entries["old"])
        XCTAssertEqual(pruned.entries.count, BlossomPresenceDisk.maxEntries)
        XCTAssertNil(pruned.entries["h0"])
        XCTAssertNotNil(pruned.entries["h\(BlossomPresenceDisk.maxEntries + 4)"])
    }

    func testRoundTripsThroughJSON() throws {
        var disk = BlossomPresenceDisk()
        disk.store(hash: "a", servers: ["s": false], now: start)
        let back = try JSONDecoder().decode(BlossomPresenceDisk.self, from: JSONEncoder().encode(disk))
        XCTAssertEqual(back, disk)
    }
}
