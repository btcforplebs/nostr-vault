import XCTest

/// LocalNotificationService pulls in the whole app and can't be built here,
/// so this reads its source: every system alert is built in the one async
/// `post` that sets `content.body`, and that body goes through
/// `NotificationPolicy.systemAlertBody`, so a DM's decrypted text never
/// reaches the lock screen. The name-based `post` titles a DM with its sender.
final class DMSystemAlertWiringTests: XCTestCase {
    private func source() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("HavenApp/Services/LocalNotificationService.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testEveryBodyGoesThroughThePolicy() throws {
        let src = try source()
        let sets = src.components(separatedBy: "content.body = ").dropFirst()
        XCTAssertEqual(sets.count, 1, "one place builds a system alert's body")
        XCTAssertTrue(sets.first?.hasPrefix("NotificationPolicy.systemAlertBody(type: type, body: body)") == true)
    }

    func testNamedPostTitlesTheSender() throws {
        let src = try source()
        let start = try XCTUnwrap(src.range(of: "private func post(id: String, type: String, name: String?"))
        let rest = src[start.upperBound...]
        let end = try XCTUnwrap(rest.range(of: "\n    }\n")).lowerBound
        XCTAssertTrue(rest[..<end].contains("NotificationPolicy.systemAlertTitle(type: type, name: name"))
    }
}
