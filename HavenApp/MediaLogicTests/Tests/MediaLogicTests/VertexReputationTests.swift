import XCTest
@testable import MediaLogic

final class VertexReputationTests: XCTestCase {

    private let service = VertexReputation.servicePubkey
    private let target = "e2ccf7cf20403f3f2a4a55b328f0de3be38558a7d5f33632fdaaefc726c1c8eb"
    private let requestId = "c863ff5e138695b1684e23e0dd6bb55bd5a17346640798633c31bc97a3371475"

    /// Content of a real kind 6312 from relay.vertexlab.io (2026-10-08),
    /// trimmed to two followers.
    private let realContent = #"[{"pubkey":"e2ccf7cf20403f3f2a4a55b328f0de3be38558a7d5f33632fdaaefc726c1c8eb","rank":0.0006655309037957871,"follows":1482,"followers":16270},{"pubkey":"82341f882b6eabcd2ba7f1ef90aad961cf074af15b9ef44a09f9d2a8fbfbe6a2","rank":0.006117609673151461},{"pubkey":"32e1827635450ebb3c5a7d12c1f8e7b2b514439ac10a67eef3d9fd9c5c68e245","rank":0.003288825790550474}]"#

    private func reply(kind: Int = VertexReputation.resultKind, pubkey: String? = nil,
                       tags: [[String]]? = nil, content: String? = nil, target: String? = nil) -> VertexReputation.Reply? {
        VertexReputation.reply(
            kind: kind, pubkey: pubkey ?? service,
            tags: tags ?? [["e", requestId], ["p", "1b8e"]],
            content: content ?? realContent, requestId: requestId, target: target ?? self.target
        )
    }

    func testRequestNamesTheTarget() {
        XCTAssertEqual(VertexReputation.requestTags(target: target), [["param", "target", target]])
    }

    func testReadsTheTargetsFollowersFromARealResult() {
        XCTAssertEqual(reply(), .followers(16270))
    }

    func testIgnoresEventsNotFromVertexOrForAnotherRequest() {
        XCTAssertNil(reply(pubkey: "ffff6af836eadef0d20a8891f65e53562e4bea181d38b25797b4ce2f4979d415"))
        XCTAssertNil(reply(tags: [["e", "5aa1430e28d4d83c356b350867769cc18ae61b15c2b0a391e6cb0a501da3de54"]]))
        XCTAssertNil(reply(tags: []))
    }

    func testAResultForADifferentProfileIsNotUsed() {
        XCTAssertEqual(reply(target: "82341f882b6eabcd2ba7f1ef90aad961cf074af15b9ef44a09f9d2a8fbfbe6a2"),
                       .failed("unreadable result"))
        XCTAssertEqual(reply(content: "not json"), .failed("unreadable result"))
    }

    func testRealNoCreditsErrorFails() {
        let tags = [["e", requestId], ["p", "ff50"],
                    ["status", "error", "you don't have enough credits to fulfil the request. Send us a DM and we'll give you a top-up for free!"]]
        guard case .failed(let message)? = reply(kind: VertexReputation.feedbackKind, tags: tags, content: "") else {
            return XCTFail("expected a refusal")
        }
        XCTAssertTrue(message.contains("credits"))
    }

    func testProcessingStatusKeepsWaiting() {
        let tags = [["e", requestId], ["status", "processing"]]
        XCTAssertNil(reply(kind: VertexReputation.feedbackKind, tags: tags, content: ""))
    }

    func testCacheKeepsAnswersForHalfAnHour() {
        var cache = VertexReputation.Cache()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        cache.record(.followers(2754), for: target, now: t0)
        XCTAssertEqual(cache.followers(for: target, now: t0.addingTimeInterval(29 * 60)), 2754)
        XCTAssertNil(cache.followers(for: target, now: t0.addingTimeInterval(31 * 60)))
        XCTAssertNil(cache.followers(for: "other", now: t0))
    }

    func testARefusalPausesAskingForHalfAnHour() {
        var cache = VertexReputation.Cache()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(cache.shouldAsk(now: t0))
        cache.record(.failed("no credits"), for: target, now: t0)
        XCTAssertFalse(cache.shouldAsk(now: t0.addingTimeInterval(29 * 60)))
        XCTAssertTrue(cache.shouldAsk(now: t0.addingTimeInterval(30 * 60)))
    }
}
