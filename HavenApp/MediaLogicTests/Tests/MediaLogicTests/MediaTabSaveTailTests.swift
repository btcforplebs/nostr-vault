import XCTest
@testable import MediaLogic

/// A save from the Media tab (Magic Paste, photo picker, Files) tells the
/// owner's other devices the same way a post's upload does: the blob goes on
/// the home vault's lane and a file note follows (Logen, 2026-11-13: a magic
/// paste on the iPhone never reached the iPad's Media tab).
final class MediaTabSaveTailTests: XCTestCase {
    private let a = "https://a.example", b = "https://b.example"

    func testNoteNamesTheServersThatTookIt() {
        XCTAssertEqual(HomeVaultLogic.mediaSaveNoteServers(configured: [a, b], accepted: [b], toHomeVault: true, isVault: false), [b])
        XCTAssertEqual(HomeVaultLogic.mediaSaveNoteServers(configured: [a, b], accepted: [b, a], toHomeVault: false, isVault: false), [a, b],
                       "configured order, not finish order")
    }

    func testNoServerTookItTheVaultHoldsIt() {
        XCTAssertEqual(HomeVaultLogic.mediaSaveNoteServers(configured: [a], accepted: [], toHomeVault: true, isVault: false), [])
        XCTAssertEqual(HomeVaultLogic.mediaSaveNoteServers(configured: [], accepted: [], toHomeVault: false, isVault: true), [],
                       "the Mac is the vault")
    }

    func testNowhereElseNoNote() {
        XCTAssertNil(HomeVaultLogic.mediaSaveNoteServers(configured: [a], accepted: [], toHomeVault: false, isVault: false))
    }

    /// The Media tab can't be built here, so this reads its source: every
    /// save goes through the one helper that runs the tail.
    func testEveryMediaTabSaveRunsTheTail() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let src = try String(contentsOf: root.appendingPathComponent("HavenApp/Views/MediaGallery/MediaGalleryUpload.swift"), encoding: .utf8)
        XCTAssertFalse(src.contains("blossom.saveToLocalRelay("), "a Media tab save skips the vault lane and file note")
        XCTAssertEqual(src.components(separatedBy: "blossom.saveFromMediaTab(").count - 1, 4,
                       "photo picker x2, Files, Magic Paste image")
        XCTAssertTrue(src.contains("blossom.downloadFromURL(url: url, fromMediaTab: true)"), "Magic Paste of a link")
    }
}
