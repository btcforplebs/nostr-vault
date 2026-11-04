import XCTest
@testable import MediaLogic

/// A post every media server refused says why, in the server's own words when it gave any (BUD-01 X-Reason; NDK
/// check step 3, Logen 2026-11-04).
final class MediaRefusalReasonTests: XCTestCase {
    private func post() -> QueuedMediaPost {
        QueuedMediaPost(accountNpub: "npub1me", body: "gm", media: [.init(sha256: String(repeating: "a", count: 64), mimeType: "image/jpeg", url: nil)], quoteSuffix: nil, baseTags: [])
    }

    func testLineCarriesTheServersReason() {
        var p = post()
        XCTAssertNil(p.refusalLine)
        p.refusedStatus = 413
        XCTAssertEqual(p.refusalLine, "Your media servers refused this file (HTTP 413). Change servers below, then tap Try sending now.")
        p.refusedReason = "file too large, max 50 MB"
        XCTAssertEqual(p.refusalLine, "Your media servers refused this file (HTTP 413: file too large, max 50 MB). Change servers below, then tap Try sending now.")
    }

    func testTryAgainForgetsTheReason() {
        var p = post()
        p.refusedStatus = 403
        p.refusedReason = "not on the allow list"
        p.resetForUserRetry()
        XCTAssertNil(p.refusedStatus)
        XCTAssertNil(p.refusedReason)
    }

    /// Posts saved before this change have no reason field and still load.
    func testOldSavedPostsStillLoad() throws {
        var p = post()
        p.refusedStatus = 403
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as! [String: Any]
        json.removeValue(forKey: "refusedReason")
        let back = try JSONDecoder().decode(QueuedMediaPost.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(back.refusedStatus, 403)
        XCTAssertNil(back.refusedReason)
    }
}
