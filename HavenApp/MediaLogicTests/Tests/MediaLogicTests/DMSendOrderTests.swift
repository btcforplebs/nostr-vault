import XCTest

/// A DM that failed to send stayed in the thread as sent: the bubble was
/// added and saved before the key was read and before the signer was asked,
/// and a signer failure after that was only printed in debug builds. Sending
/// can't run here (relays, signer, the whole app), so this reads the source:
/// both DM kinds must be signed before the message joins the thread.
final class DMSendOrderTests: XCTestCase {
    private func sendingSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("HavenApp/Services/DM/DMService+Sending.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func body(of function: String, in source: String) throws -> Substring {
        let start = try XCTUnwrap(source.range(of: "func \(function)("), "missing \(function)")
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\n    }\n")?.lowerBound ?? rest.endIndex
        return rest[..<end]
    }

    private func offset(_ needle: String, in text: Substring) throws -> Int {
        let r = try XCTUnwrap(text.range(of: needle), "missing \(needle)")
        return text.distance(from: text.startIndex, to: r.lowerBound)
    }

    func testAGiftWrappedDMIsSignedBeforeItJoinsTheThread() throws {
        let fn = try body(of: "sendNIP17DM", in: try sendingSource())
        let append = try offset("messages.append(message)", in: fn)
        XCTAssertLessThan(try offset("activePrivateKey()", in: fn), append)
        XCTAssertLessThan(try offset("try await (recipientWrap, selfWrap)", in: fn), append)
        XCTAssertLessThan(try offset("switchGeneration == generation", in: fn), append)
        XCTAssertFalse(fn.contains("} catch {"), "a signer failure must reach the caller, not a debug print")
    }

    func testALegacyDMIsSignedBeforeItJoinsTheThread() throws {
        let fn = try body(of: "sendNIP04DM", in: try sendingSource())
        let append = try offset("messages.append(message)", in: fn)
        XCTAssertLessThan(try offset("signEventAsync(", in: fn), append)
        XCTAssertLessThan(try offset("switchGeneration == generation", in: fn), append)
    }
}
