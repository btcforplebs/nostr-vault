import XCTest
@testable import MediaLogic

/// A collapsed Vault row keeps its 8-line clamp across text pieces and
/// inline link cards.
final class NoteClampTests: XCTestCase {
    private let card = NoteURLs.Segment.link(URL(string: "https://a.com")!)
    private func text(_ s: String = "t") -> NoteURLs.Segment { .text(s) }

    func testShortNoteShowsEverythingUncut() {
        let plan = NoteClamp.plan([text(), card, text()], lines: [0: 2, 2: 3], budget: 8)
        XCTAssertEqual(plan.shows, [.full, .full, .full])
        XCTAssertFalse(plan.cut)
    }

    func testBudgetRunsOutInTheSecondPiece() {
        let plan = NoteClamp.plan([text(), card, text(), card], lines: [0: 5, 2: 6], budget: 8)
        XCTAssertEqual(plan.shows, [.full, .full, .lines(3), .hidden])
        XCTAssertTrue(plan.cut)
    }

    func testLongFirstPieceHidesTheCardAfterIt() {
        let plan = NoteClamp.plan([text(), card, text()], lines: [0: 12, 2: 1], budget: 8)
        XCTAssertEqual(plan.shows, [.lines(8), .hidden, .hidden])
        XCTAssertTrue(plan.cut)
    }

    func testTextExactlyFillingTheBudgetHidesWhatFollows() {
        let plan = NoteClamp.plan([text(), card], lines: [0: 8], budget: 8)
        XCTAssertEqual(plan.shows, [.full, .hidden])
        XCTAssertTrue(plan.cut)
        XCTAssertFalse(NoteClamp.plan([text()], lines: [0: 8], budget: 8).cut)
    }

    func testCardFirstCostsNoLines() {
        let plan = NoteClamp.plan([card, text()], lines: [1: 8], budget: 8)
        XCTAssertEqual(plan.shows, [.full, .full])
        XCTAssertFalse(plan.cut)
    }

    func testUnmeasuredPieceTakesTheRestOfTheBudget() {
        let plan = NoteClamp.plan([text(), card, text()], lines: [:], budget: 8)
        XCTAssertEqual(plan.shows, [.lines(8), .hidden, .hidden])
    }

    func testLineCountFromHeights() {
        // 18pt lines, 2pt between them: 1 line 18, 3 lines 58, 8 lines 158.
        XCTAssertEqual(NoteClamp.lineCount(height: 18, lineHeight: 18, spacing: 2), 1)
        XCTAssertEqual(NoteClamp.lineCount(height: 58, lineHeight: 18, spacing: 2), 3)
        XCTAssertEqual(NoteClamp.lineCount(height: 158.4, lineHeight: 18, spacing: 2), 8)
        XCTAssertEqual(NoteClamp.lineCount(height: 40, lineHeight: 0, spacing: 2), 0)
    }
}
