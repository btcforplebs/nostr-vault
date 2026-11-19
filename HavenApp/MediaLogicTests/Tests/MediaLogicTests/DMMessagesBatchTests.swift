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

    /// B7: loading is not "No Messages Yet" / "Start a conversation".
    func testLoadingIsNotEmpty() throws {
        XCTAssertTrue(try source("HavenApp/Views/DMInboxView.swift")
            .contains("} else if dmService.isLoading && dmService.conversations.isEmpty {\n            // Still coming in"))
        XCTAssertTrue(try source("HavenApp/Views/DMThreadView.swift").contains("} else if messages.isEmpty && dmService.isLoading {"))
    }

    /// B9 + B5: the box keeps a draft, and a send that fails after you left
    /// goes to the draft and a pill instead of the closed screen.
    func testDraftsAndFailedAfterLeaving() throws {
        let thread = try source("HavenApp/Views/DMThreadView.swift")
        XCTAssertTrue(thread.contains("DMDrafts.shared.set(text, account: draftAccount, counterparty: counterpartyPubkey)"))
        XCTAssertTrue(thread.contains("guard presence.isOnScreen else {"))
        XCTAssertTrue(thread.contains("DMSendFailedAway.report("))
        XCTAssertTrue(try source("HavenApp/Services/DM/DMService+Reconnect.swift")
            .contains("DMDrafts.shared.keepOnly(account: newPubkey)"))
    }

    /// B2: one new-chat picker opens the chat; the text-only composers are gone.
    func testNewChatOpensTheChat() throws {
        let inbox = try source("HavenApp/Views/DMInboxView.swift")
        XCTAssertFalse(inbox.contains("MacComposeView"))
        XCTAssertTrue(inbox.contains("DispatchQueue.main.async { open(pubkey) }"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try appPath("HavenApp/Views/MessageComposerView.swift")))
    }

    func appPath(_ path: String) throws -> String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(path).path
    }

    func source(_ path: String) throws -> String {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: app.appendingPathComponent(path), encoding: .utf8)
    }
}
