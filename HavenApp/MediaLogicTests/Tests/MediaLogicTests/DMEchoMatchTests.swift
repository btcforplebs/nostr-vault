import XCTest
@testable import MediaLogic

/// B12: your own message returning from the relay replaces its sending
/// bubble however long a remote signer took, and only that bubble.
final class DMEchoMatchTests: XCTestCase {
    private let local = UUID().uuidString
    private let relayID = String(repeating: "ab", count: 32)

    func testTheSendingBubbleIsTheEcho() {
        XCTAssertTrue(DMEchoMatch.isEcho(id: local, isFromMe: true, isFailed: false, content: "hi", echoContent: "hi"))
    }

    func testNeverARelayEventANotSentOneOrSomeoneElses() {
        XCTAssertFalse(DMEchoMatch.isEcho(id: relayID, isFromMe: true, isFailed: false, content: "hi", echoContent: "hi"),
                       "already a relay event: a second 'hi' you sent is its own message")
        XCTAssertFalse(DMEchoMatch.isEcho(id: local, isFromMe: true, isFailed: true, content: "hi", echoContent: "hi"))
        XCTAssertFalse(DMEchoMatch.isEcho(id: local, isFromMe: false, isFailed: false, content: "hi", echoContent: "hi"))
        XCTAssertFalse(DMEchoMatch.isEcho(id: local, isFromMe: true, isFailed: false, content: "hi", echoContent: "hey"))
    }

    func testNoTimeWindow() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let wrap = try String(contentsOf: app.appendingPathComponent("HavenApp/Services/DM/DMService+GiftWrap.swift"), encoding: .utf8)
        XCTAssertFalse(wrap.contains("addingTimeInterval(-30)"))
        XCTAssertTrue(wrap.contains("DMEchoMatch.isEcho("))
    }
}
