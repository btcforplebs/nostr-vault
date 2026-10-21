import XCTest
@testable import MediaLogic

final class VaultContentsTests: XCTestCase {
    /// The relay tab's note kinds as NostrService lists them.
    private let relayTabNoteKinds = [1, 6, 30023, 1111, 9802, 1068]

    private func row(_ id: String, in contents: VaultContents) -> VaultContents.GroupRow? {
        contents.groupRows.first { $0.id == id }
    }

    func testGroupsMatchTheVaultTabScopes() {
        let groups = Dictionary(uniqueKeysWithValues: VaultContents.groups.map { ($0.id, Set($0.kinds)) })
        XCTAssertEqual(groups["notes"], VaultNoteScope.notes.kinds(from: relayTabNoteKinds, split: true))
        XCTAssertTrue(groups["articles"]!.isSuperset(of: VaultNoteScope.articles.kinds(from: relayTabNoteKinds, split: true)))
        XCTAssertEqual(groups["highlights"], VaultNoteScope.highlights.kinds(from: relayTabNoteKinds, split: true))
    }

    func testNoKindIsCountedTwice() {
        let kinds = VaultContents.countedKinds
        XCTAssertEqual(kinds.count, Set(kinds).count)
    }

    func testGroupSumsItsKindsAndCarriesYours() {
        let contents = VaultContents(total: 20, byKind: [1: 7, 6: 2, 1111: 1], yours: ["notes": 4])
        let notes = row("notes", in: contents)
        XCTAssertEqual(notes?.count, 10)
        XCTAssertEqual(notes?.yours, 4)
        XCTAssertEqual(notes?.kinds.map(\.kind), [1, 6, 1111], "largest first, empty kinds left out")
    }

    func testMessagesAndZapsHaveNoYours() {
        let contents = VaultContents(total: 7, byKind: [1059: 5, 9735: 2], yours: [:])
        XCTAssertEqual(row("messages", in: contents)?.count, 5)
        XCTAssertNil(row("messages", in: contents)?.yours)
        XCTAssertNil(row("zaps", in: contents)?.yours)
    }

    func testOtherIsWhatTheGroupsLeaveIncludingUnlistedKinds() {
        // 10 notes, 3 deletions (a listed other kind), 7 of kinds never asked about.
        let contents = VaultContents(total: 20, byKind: [1: 10, 5: 3], yours: [:])
        let other = row("other", in: contents)
        XCTAssertEqual(other?.count, 10)
        XCTAssertEqual(other?.kinds.map(\.kind), [nil, 5])
        XCTAssertEqual(other?.kinds.first?.title, "Kinds not listed")
        XCTAssertEqual(contents.groupRows.reduce(0) { $0 + $1.count }, contents.total, "rows add up to the total")
    }

    func testEmptyGroupsAreHidden() {
        let contents = VaultContents(total: 3, byKind: [7: 3], yours: ["reactions": 1])
        XCTAssertEqual(contents.groupRows.map(\.id), ["reactions"])
    }

    func testUnknownKindIsNamedByNumber() {
        XCTAssertEqual(VaultContents.kindName(31234), "Kind 31234")
        XCTAssertEqual(VaultContents.kindName(1059), "Gift-wrapped messages")
    }
}
