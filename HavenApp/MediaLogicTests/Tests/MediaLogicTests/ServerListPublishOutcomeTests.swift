import XCTest
@testable import MediaLogic

/// Settings › Media Servers Save says what its publish did (parity report gap
/// C, 2026-11-22): every refusal used to be a DEBUG print, so Save could
/// publish nothing and say nothing.
final class ServerListPublishOutcomeTests: XCTestCase {
    func testEveryRefusalSaysNothingReachedTheRelays() {
        let refusals: [ServerListPublishOutcome] = [.listNotKnown(answered: 1, asked: 5), .noRelayList, .noPublicServer, .signFailed]
        for outcome in refusals {
            XCTAssertTrue(outcome.isRefusal, "\(outcome)")
            XCTAssertTrue(outcome.message.contains("not published") || outcome.message.contains("Not published"), "\(outcome)")
        }
        XCTAssertFalse(ServerListPublishOutcome.published.isRefusal)
        XCTAssertFalse(ServerListPublishOutcome.unchanged.isRefusal)
        XCTAssertTrue(ServerListPublishOutcome.listNotKnown(answered: 1, asked: 5).message.contains("only 1 of 5 relays"))
    }

    func testOnlyPassingReasonsOfferTryAgain() {
        XCTAssertTrue(ServerListPublishOutcome.listNotKnown(answered: 0, asked: 3).canRetry)
        XCTAssertTrue(ServerListPublishOutcome.signFailed.canRetry)
        XCTAssertFalse(ServerListPublishOutcome.noRelayList.canRetry)
        XCTAssertFalse(ServerListPublishOutcome.noPublicServer.canRetry)
        XCTAssertFalse(ServerListPublishOutcome.published.canRetry)
    }

    func testRemovingTheLastPublicServerIsRefused() {
        var draft = MediaServersDraft(mirrors: ["https://blossom.example.com"])
        draft.removeMirror("https://blossom.example.com")
        XCTAssertTrue(draft.leavesNoPublicServer(published: ["https://blossom.example.com/"]))
        // A home-network server alone doesn't count.
        draft.addMirror("https://192.168.1.20")
        XCTAssertTrue(draft.leavesNoPublicServer(published: ["https://blossom.example.com"]))
    }

    func testAnotherDevicesPublicServerKeepsSaveGoing() {
        var draft = MediaServersDraft(mirrors: ["https://blossom.example.com"])
        draft.removeMirror("https://blossom.example.com")
        XCTAssertFalse(draft.leavesNoPublicServer(published: ["https://blossom.example.com", "https://other.example.org"]))
        XCTAssertFalse(draft.leavesNoPublicServer(published: [], others: ["https://mac.example.net"]))
    }

    func testUnknownPublishedListDoesNotBlock() {
        var draft = MediaServersDraft(mirrors: ["https://blossom.example.com"])
        draft.removeMirror("https://blossom.example.com")
        XCTAssertFalse(draft.leavesNoPublicServer(published: nil))
    }

    func testKeepingAPublicServerSaves() {
        var draft = MediaServersDraft(mirrors: [])
        draft.addMirror("blossom.example.com")
        XCTAssertFalse(draft.leavesNoPublicServer(published: []))
    }
}
