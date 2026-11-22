import XCTest
@testable import MediaLogic

/// Zaps and chat through the one gate (Logen 2026-11-18, call 4): a zap from
/// outside your web keeps its amount, never its words.
final class ZapGateTests: XCTestCase {
    private let me = String(repeating: "a", count: 64)
    private let friend = String(repeating: "b", count: 64)
    private let host = String(repeating: "c", count: 64)
    private let stranger = String(repeating: "d", count: 64)

    private func gate(blocked: Set<String> = []) -> WebGate.Web {
        WebGate.Web(own: [me], web: [friend], blocked: blocked)
    }

    private func chat(_ author: String?, _ text: String) -> LiveChatMessage {
        LiveChatMessage(id: "c-\(author ?? "nil")", authorPubkey: author, createdAt: 1, text: text, payload: .chat)
    }

    private func zap(_ payer: String?, sats: Int = 21, comment: String = "gm") -> LiveChatMessage {
        LiveChatMessage(id: "z-\(payer ?? "nil")", authorPubkey: payer, createdAt: 1, text: comment,
                        payload: .zap(sats: sats))
    }

    func testZapShow() {
        XCTAssertEqual(WebGate.zapShow(.inside), .whole)
        XCTAssertEqual(WebGate.zapShow(.outside), .amountOnly)
        XCTAssertEqual(WebGate.zapShow(.loose), .amountOnly)
        XCTAssertEqual(WebGate.zapShow(.blocked), .hidden)
    }

    func testChatKeepsToTheWebAndAlwaysShown() {
        XCTAssertEqual(WebGate.chatRow(chat(friend, "hi"), in: gate(), always: [host])?.text, "hi")
        XCTAssertEqual(WebGate.chatRow(chat(host, "welcome"), in: gate(), always: [host])?.text, "welcome")
        XCTAssertNil(WebGate.chatRow(chat(stranger, "spam"), in: gate(), always: [host]))
        XCTAssertNil(WebGate.chatRow(chat(nil, "who"), in: gate(), always: [host]))
        XCTAssertNil(WebGate.chatRow(chat(friend, "hi"), in: gate(blocked: [friend]), always: []))
    }

    func testOutsideZapKeepsAmountNotWords() {
        let row = WebGate.chatRow(zap(stranger, sats: 500, comment: "visit spam.example"), in: gate(), always: [])
        XCTAssertEqual(row?.zapSats, 500)
        XCTAssertEqual(row?.text, "")
        XCTAssertEqual(row?.authorPubkey, stranger)
        XCTAssertEqual(WebGate.chatRow(zap(friend, comment: "great stream"), in: gate(), always: [])?.text, "great stream")
    }

    func testUnverifiedZapNamesNobodyAndLosesItsWords() {
        let row = WebGate.chatRow(zap(nil, sats: 10, comment: "forged"), in: gate(), always: [])
        XCTAssertEqual(row?.zapSats, 10)
        XCTAssertEqual(row?.text, "")
    }

    func testBlockedPayersZapGoes() {
        XCTAssertNil(WebGate.chatRow(zap(stranger), in: gate(blocked: [stranger]), always: []))
    }

    func testMutedWordHidesAChatLine() {
        let muted = WebGate.Web(own: [me], web: [friend], mutes: MuteList(publicTags: [["word", "airdrop"]]))
        XCTAssertNil(WebGate.chatRow(chat(friend, "free AIRDROP"), in: muted, always: []))
    }
}
