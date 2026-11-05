import XCTest
@testable import MediaLogic

/// Signer audit 2026-11-05 #1: a queued NIP-46 request must use the session
/// recorded when it was made, not the one active after the wait.
final class NIP46SessionChoiceTests: XCTestCase {
    func testARecordedSessionIsUsedWhateverIsActiveLater() {
        XCTAssertEqual(NIP46SessionChoice.route(recorded: "wss://relay|signer-a"), .recorded("wss://relay|signer-a"))
    }

    func testNoRecordedSessionFallsBackToTheActiveOne() {
        XCTAssertEqual(NIP46SessionChoice.route(recorded: ""), .active)
        XCTAssertEqual(NIP46SessionChoice.route(recorded: "  "), .active)
    }

    /// Every queued sign and NIP-04/NIP-44 call in NIP46Service+Methods goes
    /// through the recorded session: the active-session C calls appear only
    /// as the `.active` fallback.
    func testQueuedCallsUseTheRecordedSession() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("HavenApp/Services/NIP46/NIP46Service+Methods.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(source.contains("NIP46SignEventWithC(p[0], p[1])"))
        XCTAssertTrue(source.contains("NIP46CryptWithC(p[0], p[1], p[2], p[3])"))
        for op in ["nip04_encrypt", "nip04_decrypt", "nip44_encrypt", "nip44_decrypt"] {
            XCTAssertTrue(source.contains("self.crypt(\"\(op)\", recorded: sessionKey"), "\(op) is not routed by its recorded session")
        }
        // Recorded before the queue wait, not inside it.
        let sign = try XCTUnwrap(source.range(of: "func signEvent(eventJSON: String) async throws -> String {"))
        let tail = source[sign.upperBound...]
        let recorded = try XCTUnwrap(tail.range(of: "let sessionKey = Self.activeSignerKey()"))
        let queued = try XCTUnwrap(tail.range(of: "signerRequest("))
        XCTAssertLessThan(recorded.lowerBound, queued.lowerBound)
        // ...and before connecting, so a switch during the connect can't move it.
        for fn in ["func signEvent(eventJSON: String)", "func nip04Encrypt(", "func nip04Decrypt(", "func nip44Encrypt(", "func nip44Decrypt("] {
            let start = try XCTUnwrap(source.range(of: fn), fn)
            let body = source[start.upperBound...]
            let key = try XCTUnwrap(body.range(of: "let sessionKey = Self.activeSignerKey()"), fn)
            let connect = try XCTUnwrap(body.range(of: "try await ensureConnected()"), fn)
            XCTAssertLessThan(key.lowerBound, connect.lowerBound, "\(fn) records its session after connecting")
        }
    }
}
