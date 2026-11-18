import XCTest
@testable import MediaLogic

/// A DM shows Sending… until a relay of theirs takes it, and Not sent when
/// none does (Apple A2, 2026-11-18; web dms.js sendMessage).
final class DMDeliveryTests: XCTestCase {
    func testTheFirstAcceptDeliversAndLaterAnswersChangeNothing() {
        var d = DMDelivery(relayCount: 3)
        XCTAssertNil(d.record(accepted: false))
        XCTAssertEqual(d.record(accepted: true), .delivered)
        XCTAssertNil(d.record(accepted: false))
        XCTAssertNil(d.expire())
        XCTAssertEqual(d.outcome, .delivered)
    }

    func testEveryRelayRefusingIsNotSent() {
        var d = DMDelivery(relayCount: 2)
        XCTAssertNil(d.record(accepted: false))
        XCTAssertEqual(d.record(accepted: false), .failed("Not delivered: none of their 2 relays took it."))
    }

    func testOneRelayWording() {
        var d = DMDelivery(relayCount: 1)
        XCTAssertEqual(d.record(accepted: false), .failed("Not delivered: none of their 1 relay took it."))
    }

    func testNoRelaysIsNotSentAtOnce() {
        XCTAssertEqual(DMDelivery(relayCount: 0).outcome, .failed("Not delivered: no relays found for them."))
    }

    func testSilenceUntilTheDeadlineIsNotSent() {
        var d = DMDelivery(relayCount: 3)
        XCTAssertNil(d.record(accepted: false))
        XCTAssertEqual(d.expire(), .failed(DMDelivery.timedOut))
        XCTAssertNil(d.record(accepted: true), "a late accept after the deadline doesn't flip it back")
    }

    // MARK: - The message's state on disk

    private func roundTrip(_ m: DMMessage) throws -> DMMessage {
        try JSONDecoder().decode(DMMessage.self, from: JSONEncoder().encode(m))
    }

    func testAFailedMessageKeepsItsStateAndReason() throws {
        let m = DMMessage(id: "a", senderPubkey: "me", content: "hi", timestamp: Date(timeIntervalSince1970: 1),
                          isFromMe: true, sendState: .failed, sendFailure: "Not delivered: x")
        let back = try roundTrip(m)
        XCTAssertTrue(back.isFailed)
        XCTAssertEqual(back.sendFailure, "Not delivered: x")
    }

    func testASendStillUnderWayWhenTheAppClosedReadsAsNotSent() throws {
        let m = DMMessage(id: "a", senderPubkey: "me", content: "hi", timestamp: Date(timeIntervalSince1970: 1),
                          isFromMe: true, sendState: .sending)
        let back = try roundTrip(m)
        XCTAssertTrue(back.isFailed)
        XCTAssertFalse(back.isSending)
        XCTAssertEqual(back.sendFailure, DMMessage.interruptedSend)
    }

    func testOldCacheWithoutTheFieldsReadsAsSent() throws {
        let json = #"{"id":"a","senderPubkey":"me","content":"hi","timestamp":0,"isFromMe":true}"#
        let m = try JSONDecoder().decode(DMMessage.self, from: Data(json.utf8))
        XCTAssertNil(m.sendState)
        XCTAssertNil(m.sendFailure)
        XCTAssertFalse(m.isSending || m.isFailed)
    }
}
