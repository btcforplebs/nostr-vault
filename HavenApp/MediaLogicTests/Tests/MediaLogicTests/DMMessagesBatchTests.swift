import XCTest

/// The Apple Messages batch from RESEARCH/NV_MESSAGES_UX_CHECK_2026_11_18.md
/// section B (Logen 2026-11-19 "go on all"). Wiring checks on the app's
/// sources; the rules themselves are tested next to their own types.
final class DMMessagesBatchTests: XCTestCase {
    /// B1: Message on a profile or in the WoT opens the real chat on every
    /// platform, not the text-only composer.
    func testProfileAndWoTMessageOpenTheChat() throws {
        for path in ["HavenApp/Views/Profile/PersonProfileView.swift", "HavenApp/Views/TrustWeb/TrustWebView.swift"] {
            let text = try source(path)
            XCTAssertFalse(text.contains("MessageComposerView("), path)
            XCTAssertTrue(text.contains("DMThreadView(counterpartyPubkey:"), path)
            XCTAssertTrue(text.contains("showsClose: true"), path)
        }
    }

    /// B8: dragging the chat puts the keyboard away.
    func testDraggingTheChatDismissesTheKeyboard() throws {
        XCTAssertTrue(try source("HavenApp/Views/DMThreadView.swift").contains(".scrollDismissesKeyboard(.interactively)"))
    }

    func source(_ path: String) throws -> String {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: app.appendingPathComponent(path), encoding: .utf8)
    }
}
