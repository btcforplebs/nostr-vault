import XCTest
@testable import MediaLogic

/// Moving in's list history scan lines (haven-go list_history_scan.go).
final class ListHistoryScanTests: XCTestCase {
    private func parse(_ line: String) -> RelayLogParser.BatchedStateUpdate {
        var batch = RelayLogParser.BatchedStateUpdate()
        RelayLogParser.collectStateChanges(from: line, into: &batch)
        return batch
    }

    func testStartShowsSkip() {
        let b = parse("2026/11/04 09:00:00 📜 looking for older versions of your lists")
        XCTAssertEqual(b.listHistoryScanning, true)
        XCTAssertEqual(b.importStatusMessage, ListHistoryScan.lookingStatus)
        XCTAssertNil(b.listHistoryNote)
    }

    func testSkipHidesSkipButKeepsNoNote() {
        let b = parse("2026/11/04 09:00:10 📜 skipping the rest of the list history scan")
        XCTAssertEqual(b.listHistoryScanning, false)
        XCTAssertNil(b.listHistoryNote)
    }

    /// The count line is not read as a notes line ("Imported … notes"), and
    /// it doesn't end the import.
    func testCountLineIsTheNote() {
        let b = parse("2026/11/04 09:01:00 📜 Found 12 older versions of your lists.")
        XCTAssertEqual(b.listHistoryScanning, false)
        XCTAssertEqual(b.listHistoryNote, "Found 12 older versions of your lists.")
        XCTAssertEqual(b.eventsStoredDelta, 0)
        XCTAssertNil(b.importProgress)
        XCTAssertEqual(ImportTourStage(statusMessage: b.importStatusMessage ?? "", completed: false),
                       ImportTourStage(text: "Looking through your history…", step: 2), "the tour moves on to the notes")
    }

    func testOtherLinesUntouched() {
        let b = parse("2026/10/08 00:28:01 📦 Imported 7 notes from 2024-03-05 to 2024-03-15")
        XCTAssertNil(b.listHistoryScanning)
        XCTAssertNil(b.listHistoryNote)
    }

    func testTourHeadline() {
        let stage = ImportTourStage(statusMessage: ListHistoryScan.lookingStatus, completed: false)
        XCTAssertEqual(stage, ImportTourStage(text: "Looking for older versions of your lists…", step: 2))
    }

    func testOnByDefault() {
        XCTAssertTrue(ListHistoryScan.defaultOn)
    }

    func testLabelIsLogensWording() {
        XCTAssertEqual(ListHistoryScan.optInLabel, "Look up and back up my lists")
        XCTAssertEqual(ListHistoryScan.optInDetail, "Finds older versions using Lazarus spec")
        XCTAssertEqual(ListHistoryScan.optInDetailLink, "Lazarus")
        XCTAssertEqual(ListHistoryScan.lazarusURL.absoluteString, "https://github.com/dmnyc/lazarus")
        XCTAssertEqual(ListHistoryScan.optInEnv, "HAVEN_IMPORT_LIST_HISTORY")
        XCTAssertEqual(ListHistoryScan.accountEnv, "HAVEN_IMPORT_LIST_HISTORY_ACCOUNT")
    }
}

/// Tron's probe (PR 1639): 200 follows cut to 50 on purpose with Amethyst in
/// 2025, then 10 more edits. The vault filed only the newest; the import
/// found the rest. Recover shows them all; the banner raises nothing.
final class ListHistoryImportAlarmTests: XCTestCase {
    private func follows(_ n: Int, at: Int64, id: String, client: String? = nil) -> ListVersion {
        var tags = (0..<n).map { ["p", String(format: "%064x", $0 + 1)] }
        if let client { tags.append(["client", client]) }
        return ListVersion(id: id, pubkey: "me", kind: 3, createdAt: at, tags: tags, content: "")
    }

    func testImportedClobberRaisesNoAlarm() {
        let cut: Int64 = 1_750_000_000
        var imported = [follows(200, at: cut - 86_400, id: "full"), follows(50, at: cut, id: "cut", client: "Amethyst")]
        for i in 1...10 { imported.append(follows(50 + i, at: cut + Int64(i) * 86_400, id: "edit\(i)")) }
        let own = [follows(61, at: 1_790_000_000, id: "now")]
        let all = (own + imported).sorted { $0.createdAt > $1.createdAt }
        let ids = Set(imported.map(\.id))

        // Control: judged together, the old cut is an alarm.
        let merged = ListWipeAlarmRule.alarm(all, own: [], dismissed: [])
        XCTAssertEqual(merged?.from, 200)
        XCTAssertEqual(merged?.to, 50)
        XCTAssertEqual(merged?.client, "Amethyst")

        let input = ListHistoryScan.alarmInput(all, imported: ids)
        XCTAssertEqual(input.map(\.id), ["now"])
        XCTAssertNil(ListWipeAlarmRule.alarm(input, own: [], dismissed: []))
        XCTAssertEqual(ListHistoryScan.alarmInput(all, imported: []).count, 13, "nothing imported: all judged")
    }
}
