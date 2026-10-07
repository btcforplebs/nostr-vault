import XCTest
@testable import MediaLogic

/// The messages here are the exact strings `RelayLogParser` sets.
final class ImportTourStageTests: XCTestCase {
    func testStagesFollowTheImport() {
        XCTAssertEqual(ImportTourStage(statusMessage: "Starting import for npub1abc...", completed: false).step, 1)
        XCTAssertEqual(ImportTourStage(statusMessage: "Connected to relays...", completed: false).step, 1)
        XCTAssertEqual(ImportTourStage(statusMessage: "Building Web of Trust...", completed: false).step, 1)
        XCTAssertEqual(ImportTourStage(statusMessage: "Analysing Web of Trust...", completed: false).step, 1)
        XCTAssertEqual(ImportTourStage(statusMessage: "Found notes from 2024-03-05...", completed: false),
                       ImportTourStage(text: "Saving your notes from Mar 2024…", step: 2))
        XCTAssertEqual(ImportTourStage(statusMessage: "Found notes...", completed: false),
                       ImportTourStage(text: "Saving your notes…", step: 2))
        XCTAssertEqual(ImportTourStage(statusMessage: "Importing tagged notes...", completed: false).step, 3)
        XCTAssertEqual(ImportTourStage(statusMessage: "Import Complete!", completed: true).step, 4)
    }

    func testMonthParsing() {
        XCTAssertEqual(ImportTourStage.month(in: "Found notes from 2023-01-31T12:00:00Z..."), "Jan 2023")
        XCTAssertEqual(ImportTourStage.month(in: "Found notes from 2021-12-01 ..."), "Dec 2021")
        XCTAssertNil(ImportTourStage.month(in: "Found notes from yesterday..."))
        XCTAssertNil(ImportTourStage.month(in: "Found notes..."))
    }
}
