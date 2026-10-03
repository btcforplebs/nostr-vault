import XCTest
@testable import MediaLogic

/// A mention's tap target and its label come from one decoder, and nothing in
/// note text or a profile name can turn into a link the app did not build.
final class MentionLinkTests: XCTestCase {
    private let pubkey = "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d"
    private var pubkeyBytes: [UInt8] {
        stride(from: 0, to: pubkey.count, by: 2).map {
            let i = pubkey.index(pubkey.startIndex, offsetBy: $0)
            return UInt8(pubkey[i..<pubkey.index(i, offsetBy: 2)], radix: 16)!
        }
    }

    private func tlv(_ type: UInt8, _ value: [UInt8]) -> [UInt8] { [type, UInt8(value.count)] + value }

    // MARK: decoding

    func testNprofileGivesThePubkeyNotTheWholePayload() {
        // NIP-19's example: the pubkey, then two relay hints.
        let payload = Data(tlv(0, pubkeyBytes) + tlv(1, Array("wss://r.x.com".utf8)) + tlv(1, Array("wss://djbas.sadkb.com".utf8)))
        XCTAssertEqual(QuoteReference.profilePubkey(hrp: "nprofile", payload: payload), pubkey)
    }

    func testRelayHintBeforeThePubkeyIsSkipped() {
        let payload = Data(tlv(1, Array("wss://r.x.com".utf8)) + tlv(0, pubkeyBytes))
        XCTAssertEqual(QuoteReference.profilePubkey(hrp: "nprofile", payload: payload), pubkey)
    }

    func testNpubIsItsThirtyTwoBytes() {
        XCTAssertEqual(QuoteReference.profilePubkey(hrp: "npub", payload: Data(pubkeyBytes)), pubkey)
    }

    func testAnythingButThirtyTwoBytesIsRefused() {
        XCTAssertNil(QuoteReference.profilePubkey(hrp: "npub", payload: Data(pubkeyBytes.dropLast())))
        XCTAssertNil(QuoteReference.profilePubkey(hrp: "nprofile", payload: Data(tlv(0, Array(pubkeyBytes.dropLast())))))
        XCTAssertNil(QuoteReference.profilePubkey(hrp: "nprofile", payload: Data(tlv(1, Array("wss://r.x.com".utf8)))))
        XCTAssertNil(QuoteReference.profilePubkey(hrp: "note", payload: Data(pubkeyBytes)))
    }

    // MARK: spoofing

    private func linkTargets(_ markdown: String) throws -> [String] {
        let attributed = try AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        return attributed.runs.compactMap { $0.link?.absoluteString }
    }

    func testAProfileNameCannotPointTheMentionElsewhere() throws {
        let name = "@Alice](https://evil.example) [x"
        let built = "**[\(MarkdownEscape.label(name))](nostr:npub1abc)**"
        let targets = try linkTargets(built)
        XCTAssertFalse(targets.isEmpty)
        XCTAssertTrue(targets.allSatisfy { $0 == "nostr:npub1abc" }, "\(targets)")
        // The name still reads as typed.
        let shown = String(try AttributedString(markdown: built, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)).characters)
        XCTAssertEqual(shown, name)
    }

    /// Every link in the rendered text reads as exactly where it goes. (The
    /// parser autolinks a bare URL left behind once the label is escaped —
    /// that link shows its own address, so it cannot pose as anything.)
    private func disguisedLinks(_ markdown: String) throws -> [String] {
        let attributed = try AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        return attributed.runs.compactMap { run -> String? in
            guard let link = run.link else { return nil }
            let shown = String(attributed[run.range].characters)
            return shown == link.absoluteString ? nil : "\(shown) -> \(link)"
        }
    }

    func testHandWrittenLinksInANoteCannotDisguiseWhereTheyGo() throws {
        for text in ["[@jack](nostr:npub1mallory)", "[google.com](https://evil.example)"] {
            XCTAssertFalse(try disguisedLinks(text).isEmpty, "control: unescaped \(text) must be a disguised link")
            XCTAssertEqual(try disguisedLinks(MarkdownEscape.linkSyntax(in: text)), [], text)
        }
        // A backslash typed before the bracket must not cancel the escape:
        // escaping "[" alone would turn this into a live link again.
        let preEscaped = #"\[@jack\](nostr:npub1mallory)"#
        XCTAssertFalse(try disguisedLinks(preEscaped.replacingOccurrences(of: "[", with: #"\["#).replacingOccurrences(of: "]", with: #"\]"#)).isEmpty,
                       "control: escaping brackets but not backslashes is beatable")
        XCTAssertEqual(try disguisedLinks(MarkdownEscape.linkSyntax(in: preEscaped)), [])
    }

    func testEscapedTextReadsAsTyped() throws {
        let text = #"see [this](x) and C:\path, *bold* stays"#
        let shown = String(try AttributedString(markdown: MarkdownEscape.linkSyntax(in: text), options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)).characters)
        XCTAssertEqual(shown, #"see [this](x) and C:\path, bold stays"#)
    }
}
