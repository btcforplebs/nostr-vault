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

/// The Vault tab's red dot needs the kind of what came in, to say where to look.
final class RelayLogParserInboxActivityTests: XCTestCase {
    private func kinds(_ lines: [String]) -> Set<Int> {
        var batch = RelayLogParser.BatchedStateUpdate()
        for line in lines { RelayLogParser.collectStateChanges(from: line, into: &batch) }
        return batch.inboxActivityKinds
    }

    /// Each phrase `logInboxImport` (haven-go/import.go) prints.
    func testEachImportLineReportsItsKind() {
        XCTAssertEqual(kinds(["2026/10/09 14:51:39 📰 new note in your inbox"]), [1])
        XCTAssertEqual(kinds(["2026/10/09 14:51:39 🤙 new reaction in your inbox"]), [7])
        XCTAssertEqual(kinds(["2026/10/09 14:51:39 ⚡️ new zap in your inbox"]), [9735])
        XCTAssertEqual(kinds(["2026/10/09 14:51:39 🔒✉️ new encrypted message in your inbox"]), [4])
        XCTAssertEqual(kinds(["2026/10/09 14:51:39 🎁🔒️✉️ new gift-wrapped message in your chat relay"]), [1059])
        XCTAssertEqual(kinds(["2026/10/09 14:51:39 🔁 new repost in your inbox"]), [6])
        XCTAssertEqual(kinds(["2026/10/09 14:51:39 📦 new event kind 9802 event in your inbox"]), [9802])
    }

    /// A reaction's content leads its line; a "new note" in it is not a note.
    func testReactionContentDoesNotReadAsANote() {
        XCTAssertEqual(kinds(["2026/10/09 14:51:39 new note in your inbox new reaction in your inbox"]), [7])
    }

    func testOwnWritesAndOtherLinesReportNothing() {
        XCTAssertEqual(kinds([
            "2026/10/09 14:51:39 event stored",
            "2026/10/09 14:51:39 blasted event to 12 relays",
            "2026/10/09 14:51:39 new note saved to outbox",
        ]), [])
    }

    func testABatchCollectsEveryKind() {
        XCTAssertEqual(kinds([
            "📰 new note in your inbox",
            "⚡️ new zap in your inbox",
            "📰 new note in your inbox",
        ]), [1, 9735])
    }
}
