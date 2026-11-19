import XCTest
@testable import MediaLogic

/// B2 + B3: the new-chat box takes npub, nprofile, hex and names alike on
/// every Apple platform, says when nothing matches, and never offers a
/// blocked person or your own account.
final class DMRecipientQueryTests: XCTestCase {
    private let alice = String(repeating: "a1", count: 32)
    private let bob = String(repeating: "b2", count: 32)
    private let me = String(repeating: "cc", count: 32)
    private var names: [String: String] { [alice: "Alice", bob: "Bob Alison", me: "Me Alias"] }

    private func resolve(_ text: String, blocked: Set<String> = []) -> DMRecipientQuery.Outcome {
        DMRecipientQuery.resolve(text, names: names, blocked: blocked, own: me)
    }

    private func npub(_ hex: String) -> String {
        Bech32.encode(hrp: "npub", data: Data(hexPairs(hex)))!
    }

    private func hexPairs(_ hex: String) -> [UInt8] {
        stride(from: 0, to: hex.count, by: 2).map {
            let start = hex.index(hex.startIndex, offsetBy: $0)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
        }
    }

    func testKeysNameOnePersonLoadedOrNot() {
        let stranger = String(repeating: "dd", count: 32)
        XCTAssertEqual(resolve(npub(stranger)), .key(stranger), "an unloaded npub still works")
        XCTAssertEqual(resolve("nostr:" + npub(alice)), .key(alice))
        XCTAssertEqual(resolve(stranger.uppercased()), .key(stranger), "hex")
        let nprofile = NostrWebLink.nprofile(pubkey: bob)!
        XCTAssertEqual(resolve(nprofile), .key(bob))
        XCTAssertEqual(resolve("npub1notakey"), .badKey)
        XCTAssertEqual(resolve(npub(me)), .yourself)
    }

    func testNamesSearchLoadedProfilesBestFirst() {
        XCTAssertEqual(resolve("ali"), .matches([alice, bob]), "prefix match first; never yourself")
        XCTAssertEqual(resolve("zz"), .noMatch)
        XCTAssertEqual(resolve("a"), .idle)
    }

    func testBlockedPeopleNeverComeUp() {
        XCTAssertEqual(resolve("ali", blocked: [alice]), .matches([bob]))
        XCTAssertEqual(resolve(npub(alice), blocked: [alice]), .blocked)
    }
}
