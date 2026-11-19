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

    /// B6: rows and the chat header fetch a profile that isn't loaded.
    func testNamesAreFetched() throws {
        XCTAssertTrue(try source("HavenApp/Views/DMInboxView.swift")
            .contains(".onAppear { nostrService.fetchMissingProfiles(for: [conversation.id]) }"))
        XCTAssertTrue(try source("HavenApp/Views/DMThreadView.swift")
            .contains("nostrService.fetchMissingProfiles(for: [counterpartyPubkey])"))
    }

    /// B3: a chat with someone blocked shows no history and takes no message.
    func testBlockedChatTakesNoMessage() throws {
        let thread = try source("HavenApp/Views/DMThreadView.swift")
        XCTAssertTrue(thread.contains("!isBlocked && !isSending"))
        XCTAssertTrue(thread.contains("isBlocked ? [] : conversation?.messages ?? []"))
        XCTAssertTrue(thread.contains(".disabled(isBlocked)"))
        XCTAssertTrue(thread.contains("DMBlockedNotice()"))
    }

    func source(_ path: String) throws -> String {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: app.appendingPathComponent(path), encoding: .utf8)
    }
}
