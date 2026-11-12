import XCTest
@testable import MediaLogic

/// The parser runs ~50 substring scans, a lowercased copy and (window up)
/// two regexes per line, so one 200 KB line cost as much as thousands of
/// normal ones; the Mac reader sat at a full core on Logen's .99 Mac
/// (2026-11-11). Lines are capped before parsing; marker lines stay whole.
final class RelayLogLineCapTests: XCTestCase {
    func testAHugeLineIsCappedForParsing() {
        let huge = "2026/11/11 19:17:00 INFO blasted event " + String(repeating: "x", count: 200_000)
        let lines = RelayLogParser.lines(in: huge + "\nshort line\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertLessThanOrEqual(lines[0].utf8.count, RelayLogParser.maxParsedLineBytes)
        XCTAssertTrue(lines[0].hasPrefix("2026/11/11 19:17:00 INFO blasted event"))
        XCTAssertEqual(lines[1], "short line")
    }

    /// A notification marker with a long recipient list reaches the
    /// notification service whole.
    func testANotifyMarkerStaysWhole() {
        let recipients = Array(repeating: String(repeating: "a", count: 64), count: 200).joined(separator: ",")
        let marker = "2026/11/11 19:17:00 🔔NOTIFY|type=reply|kind=1|author=b|id=c|recipient=d|recipients=\(recipients)|preview=hi"
        XCTAssertGreaterThan(marker.utf8.count, RelayLogParser.maxParsedLineBytes)
        XCTAssertEqual(RelayLogParser.lines(in: marker + "\n"), [marker])
    }

    func testCappingNeverSplitsACharacter() {
        let line = String(repeating: "é", count: RelayLogParser.maxParsedLineBytes)
        let out = RelayLogParser.lines(in: line + "\n")
        XCTAssertEqual(out.count, 1)
        XCTAssertTrue(out[0].allSatisfy { $0 == "é" })
    }

    func testNormalLinesAreUntouched() {
        XCTAssertEqual(RelayLogParser.lines(in: "a\n\nb c\n"), ["a", "b c"])
    }
}

/// LogEntry.parse's key=value regex retried from every character of a long
/// word: 0.8 s for one 4 KB line, 55 s for 32 KB (2026-11-12).
final class RelayLogEntryParseCostTests: XCTestCase {
    func testALongWordParsesFast() {
        let line = "2026/11/11 19:17:00 INFO blasted event " + String(repeating: "x", count: 4_000)
        let start = Date()
        _ = RelayLogParser.LogEntry.parse(line)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.2)
    }

    func testKeyValuesStillRead() {
        let entry = RelayLogParser.LogEntry.parse("2026/11/11 19:17:00 INFO stored kind=1 id=ab")
        XCTAssertEqual(entry.message, "stored kind: 1 id: ab")
    }
}
