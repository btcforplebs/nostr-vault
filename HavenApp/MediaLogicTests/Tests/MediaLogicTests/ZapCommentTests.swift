import XCTest
@testable import MediaLogic

/// A zap carries only what the user wrote (Logen, 11-01): no app-supplied text.
final class ZapCommentTests: XCTestCase {
    func testNothingTypedSendsNothing() {
        XCTAssertEqual(ZapComment.content(""), "")
        XCTAssertEqual(ZapComment.content("   \n\t "), "")
    }

    func testTypedCommentIsTrimmed() {
        XCTAssertEqual(ZapComment.content("  great set!\n"), "great set!")
    }

    func testLongCommentIsCapped() {
        let long = String(repeating: "a", count: ZapComment.maxLength + 50)
        XCTAssertEqual(ZapComment.content(long).count, ZapComment.maxLength)
    }

    /// The default must stay empty: the old "Zap from Nostr Vault" was signed
    /// into every one-tap zap without the user seeing it.
    func testNoAppDefaultInZapService() throws {
        let here = URL(fileURLWithPath: #filePath)
        let root = here.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let service = try String(contentsOf: root.appendingPathComponent("HavenApp/Services/ZapService.swift"), encoding: .utf8)
        XCTAssertTrue(service.contains("message: String = \"\""))
        XCTAssertFalse(service.contains("Nostr Vault\""))
    }
}
