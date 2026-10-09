import XCTest
@testable import MediaLogic

/// A " to" earlier in the line than "for "/"from " used to make the status
/// slice's end precede its start, trapping the app mid-import.
final class RelayLogParserRangeTests: XCTestCase {
    func testImportedLineWithEarlierToDoesNotTrap() {
        var batch = RelayLogParser.BatchedStateUpdate()
        RelayLogParser.collectStateChanges(from: "Imported 12 notes to the vault from 2024-03-05 to 2024-03-15", into: &batch)
        XCTAssertEqual(batch.importStatusMessage, "Found notes from 2024-03-05...")
        XCTAssertEqual(batch.eventsStoredDelta, 12)
    }

    func testImportedLineWithOnlyEarlierToFallsBack() {
        var batch = RelayLogParser.BatchedStateUpdate()
        RelayLogParser.collectStateChanges(from: "Imported 4 notes to inbox from relay.damus.io", into: &batch)
        XCTAssertEqual(batch.importStatusMessage, "Found notes...")
    }

    func testNoNotesLineWithEarlierToDoesNotTrap() {
        var batch = RelayLogParser.BatchedStateUpdate()
        RelayLogParser.collectStateChanges(from: "switched to fallback: No notes found for 2021-05-21 to 2021-05-31", into: &batch)
        XCTAssertEqual(batch.importStatusMessage, "Looking through notes from 2021-05-21...")
    }

    /// The exact import.go format still parses as before.
    func testImportGoFormatUnchanged() {
        var batch = RelayLogParser.BatchedStateUpdate()
        RelayLogParser.collectStateChanges(from: "2026/10/08 00:28:01 📦 Imported 7 notes from 2024-03-05 to 2024-03-15", into: &batch)
        XCTAssertEqual(batch.importStatusMessage, "Found notes from 2024-03-05...")
        XCTAssertEqual(batch.progressDateStr, "2024-03-15")
    }

    /// The real trigger (Fred's re-shoot, 2026-10-08): a Swift print and a Go
    /// log line share the stdout pipe and got spliced onto one line, so the
    /// " to" of the cache path came before "for ".
    func testSplicedMediaCacheLineDoesNotTrap() {
        var batch = RelayLogParser.BatchedStateUpdate()
        RelayLogParser.collectStateChanges(from: "MediaCacheService: Cached favicon.jpg to /Users/x/Library/Application Support/Haven/haven_database/cache/11d4e86e92026/10/08 21:57:39 ℹ️ No notes found for 2023-08-09 to 2023-08-19", into: &batch)
        XCTAssertEqual(batch.importStatusMessage, "Looking through notes from 2023-08-09...")
        XCTAssertEqual(batch.progressDateStr, "2023-08-19")
    }
}
