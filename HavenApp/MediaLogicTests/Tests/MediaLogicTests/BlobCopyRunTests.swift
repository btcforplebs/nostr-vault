import XCTest
@testable import MediaLogic

/// A server is marked as refusing the key only on a 401, or on a 403 for two
/// different files: one 403 can be about that file alone.
final class BlobCopyRunTests: XCTestCase {
    private let server = "https://media.example"
    private let other = "https://other.example"

    func testA401MarksTheServerAtOnce() async {
        let run = BlobCopyRun()
        await run.noteRefusal(server, hash: "a", status: 401, reason: "not on the list")
        let reason = await run.refusal(server)
        XCTAssertEqual(reason, "not on the list")
        let untouched = await run.refusal(other)
        XCTAssertNil(untouched)
    }

    func testOne403LeavesTheServerOpen() async {
        let run = BlobCopyRun()
        await run.noteRefusal(server, hash: "a", status: 403, reason: "no videos")
        let reason = await run.refusal(server)
        XCTAssertNil(reason)
    }

    func testTheSame403FileTwiceLeavesTheServerOpen() async {
        let run = BlobCopyRun()
        await run.noteRefusal(server, hash: "a", status: 403, reason: "no videos")
        await run.noteRefusal(server, hash: "a", status: 403, reason: "no videos")
        let reason = await run.refusal(server)
        XCTAssertNil(reason)
    }

    func test403ForTwoFilesMarksTheServer() async {
        let run = BlobCopyRun()
        await run.noteRefusal(server, hash: "a", status: 403, reason: "first")
        await run.noteRefusal(server, hash: "b", status: 403, reason: "second")
        let reason = await run.refusal(server)
        XCTAssertEqual(reason, "second")
    }
}
