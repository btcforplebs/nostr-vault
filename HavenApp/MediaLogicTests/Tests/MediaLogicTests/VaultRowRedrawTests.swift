import XCTest
@testable import MediaLogic

/// Vault review 2026-11-27 #1 and #2: hidden tabs and Vault rows redrew on
/// every store change, and each row redraw searched the store or re-parsed
/// its note.
final class VaultRowRedrawTests: XCTestCase {
    private var appRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: appRoot.appendingPathComponent(path), encoding: .utf8)
    }

    private func npub(_ byte: UInt8) -> String {
        Bech32.encode(hrp: "npub", data: Data(repeating: byte, count: 32))!
    }

    func testAccountHexesDecodeEveryNpub() {
        let hexes = AccountHexMemo.hexes(of: [npub(1), npub(2), "not-an-npub"])
        XCTAssertEqual(hexes, [String(repeating: "01", count: 32), String(repeating: "02", count: 32)])
    }

    func testAccountHexesFollowAChangedList() {
        _ = AccountHexMemo.hexes(of: [npub(1)])
        XCTAssertEqual(AccountHexMemo.hexes(of: [npub(3)]), [String(repeating: "03", count: 32)])
        XCTAssertEqual(AccountHexMemo.hexes(of: []), [])
    }

    /// The tab shell holds the three services without observing them, so a
    /// profile, note or DM landing doesn't rebuild every tab.
    func testTabShellDoesNotObserveTheServices() throws {
        let shell = try source("HavenApp-iOS/Shell/iPhoneTabView.swift")
        XCTAssertTrue(shell.contains("struct iPhoneTabView"), "positive control")
        for service in ["NostrService", "FeedService", "DMService"] {
            XCTAssertFalse(shell.contains("@StateObject private var \(service.prefix(1).lowercased() + service.dropFirst()) "),
                           "\(service) observed by the shell")
            XCTAssertFalse(shell.contains("@ObservedObject private var \(service.prefix(1).lowercased() + service.dropFirst()) "),
                           "\(service) observed by the shell")
        }
        XCTAssertTrue(shell.contains("private let nostrService = NostrService.shared"))
    }

    /// A Vault row's link looks its note up on the tap, not in the body.
    func testVaultRowLinkDoesNotSearchTheStoreInItsBody() throws {
        let list = try source("HavenApp/Views/Vault/VaultActivityList.swift")
        let body = try XCTUnwrap(list.range(of: "private func singleAccountLink"))
        let end = try XCTUnwrap(list.range(of: "private func openActivityNote"))
        XCTAssertLessThan(body.lowerBound, end.lowerBound)
        XCTAssertFalse(list[body.lowerBound..<end.lowerBound].contains("events.first("))
        XCTAssertTrue(list[end.lowerBound...].contains("events.first("), "positive control: the tap looks it up")
    }

    /// Note rows take their repost, media and links from the per-event memo.
    func testNoteRowUsesTheParseMemo() throws {
        let layout = try source("HavenApp/Views/Vault/NoteRow+ExpandedLayout.swift")
        XCTAssertFalse(layout.contains("event.mediaURLs"))
        XCTAssertFalse(layout.contains("event.linkURLs"))
        XCTAssertTrue(layout.contains("parsed.mediaURLs"))
        let row = try source("HavenApp/Views/Vault/VaultNoteRow.swift")
        XCTAssertFalse(row.contains("RelativeDateTimeFormatter()"))
        XCTAssertFalse(row.contains("JSONDecoder()"))
    }
}
