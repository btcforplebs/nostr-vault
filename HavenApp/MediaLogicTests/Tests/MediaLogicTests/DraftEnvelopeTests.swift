import XCTest
@testable import MediaLogic

/// Drafts (kind 31234) on the vault's /private relay are NIP-37: the note's
/// text and tags are NIP-44 encrypted to the author's own key, and only `d`
/// and `k` are left outside. Drafts saved before that, in plain text, still open.
final class DraftEnvelopeTests: XCTestCase {
    /// A stand-in for NIP-44 to self that keeps nothing readable: the real
    /// cipher is the signer's (MuteListStore.encryptToSelf), not built here.
    /// It produces a v2-shaped payload (base64, first byte 2) so `open` treats it as encrypted.
    private static func fakeEncrypt(_ plain: String) -> String {
        var bytes: [UInt8] = [2] + Array(repeating: 0x11, count: 32)
        bytes += Array(plain.utf8).map { $0 ^ 0x5A }
        bytes += Array(repeating: 0x22, count: max(0, 99 - bytes.count))
        bytes += [UInt8(truncatingIfNeeded: plain.utf8.count >> 8), UInt8(truncatingIfNeeded: plain.utf8.count)]
        return Data(bytes).base64EncodedString()
    }

    private static func fakeDecrypt(_ payload: String) throws -> String {
        guard let data = Data(base64Encoded: payload), data.count >= 99, data.first == 2 else { throw URLError(.cannotDecodeContentData) }
        let b = Array(data)
        let len = Int(b[b.count - 2]) << 8 | Int(b[b.count - 1])
        return String(decoding: b[33..<(33 + len)].map { $0 ^ 0x5A }, as: UTF8.self)
    }

    private let secret = "meet at the old mill at 9, bring the key"
    private let replyTags: [[String]] = [
        ["d", "DRAFT-1"], ["k", "1"],
        ["e", String(repeating: "a", count: 64), "", "root"],
        ["e", String(repeating: "b", count: 64), "wss://10.0.0.1:3355", "reply"],
        ["p", String(repeating: "c", count: 64)],
        ["q", String(repeating: "d", count: 64), "wss://relay", String(repeating: "e", count: 64)],
    ]
    private let saved = Date(timeIntervalSince1970: 1_790_000_000)

    /// The text never leaves the app: not in the content, not in a tag.
    func testSealedDraftCarriesNoPlaintext() async throws {
        let sealed = try await DraftEnvelope.seal(content: secret, tags: replyTags, updatedAt: saved,
                                                  encrypt: { Self.fakeEncrypt($0) })
        XCTAssertFalse(sealed.content.contains("old mill"))
        XCTAssertFalse(sealed.content.contains(secret))
        XCTAssertTrue(DraftEnvelope.looksEncrypted(sealed.content))
        XCTAssertFalse(sealed.tags.flatMap { $0 }.contains { $0.contains("old mill") })
    }

    /// Who it answers and who it names stay inside too: only d and k are outside.
    func testOnlyDAndKAreLeftOutside() async throws {
        let sealed = try await DraftEnvelope.seal(content: secret, tags: replyTags, updatedAt: saved,
                                                  encrypt: { Self.fakeEncrypt($0) })
        XCTAssertEqual(sealed.tags, [["d", "DRAFT-1"], ["k", "1"]])
    }

    /// What is encrypted is NIP-37's draft event: kind, content, tags (not d/k), created_at.
    func testInsideIsTheDraftEvent() async throws {
        var inner = ""
        _ = try await DraftEnvelope.seal(content: secret, tags: replyTags, updatedAt: saved,
                                         encrypt: { inner = $0; return Self.fakeEncrypt($0) })
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(inner.utf8)) as? [String: Any])
        XCTAssertEqual(obj["kind"] as? Int, 1)
        XCTAssertEqual(obj["content"] as? String, secret)
        XCTAssertEqual(obj["created_at"] as? Int, 1_790_000_000)
        XCTAssertEqual(obj["tags"] as? [[String]], Array(replyTags.dropFirst(2)))
    }

    /// Saved and fetched back, a draft is the same draft: text, every tag in the old shape, and its time.
    func testRoundTripGivesTheDraftBack() async throws {
        let sealed = try await DraftEnvelope.seal(content: secret, tags: replyTags, updatedAt: saved,
                                                  encrypt: { Self.fakeEncrypt($0) })
        let maybe = await DraftEnvelope.open(content: sealed.content, tags: sealed.tags,
                                             decrypt: { try Self.fakeDecrypt($0) })
        let opened = try XCTUnwrap(maybe)
        XCTAssertEqual(opened.content, secret)
        XCTAssertEqual(opened.tags, replyTags)
        XCTAssertEqual(opened.createdAt, saved)
        XCTAssertFalse(opened.wasPlaintext)
    }

    /// A draft saved before encryption still opens, as it was, and is marked
    /// so the service saves it again encrypted. Nothing is decrypted for it.
    func testOldPlaintextDraftStillOpens() async throws {
        var asked = false
        let maybe = await DraftEnvelope.open(content: secret, tags: replyTags,
                                             decrypt: { asked = true; return try Self.fakeDecrypt($0) })
        let opened = try XCTUnwrap(maybe)
        XCTAssertEqual(opened.content, secret)
        XCTAssertEqual(opened.tags, replyTags)
        XCTAssertNil(opened.createdAt)
        XCTAssertTrue(opened.wasPlaintext)
        XCTAssertFalse(asked)
    }

    /// Old drafts are often short or empty, and may be base64-looking words: still plain text.
    func testShortAndEmptyOldDraftsArePlaintext() async throws {
        for text in ["", "x", "hello", "QUJD", String(repeating: "A", count: 131)] {
            let opened = await DraftEnvelope.open(content: text, tags: [["d", "1"], ["k", "1"]], decrypt: { _ in "" })
            XCTAssertEqual(opened?.content, text)
            XCTAssertEqual(opened?.wasPlaintext, true, text)
        }
    }

    /// The one rule both apps use (Android DraftEnvelopeTest.sharedDetectionVectors,
    /// same list): a miss shows ciphertext as text and saves it again, so
    /// anything shaped like a NIP-44 payload counts, padded or not.
    func testSharedDetectionVectors() {
        let payload = "AgMKERgfJi00O0JJUFdeZWxzeoGIj5adpKuyucDHztXc4+rx+P8GDRQbIikwNz5FTFNaYWhvdn2Ei5KZoKeutbzDytHY3+bt9PsCCRAXHiUsMzpBSE9WXWRrcnmAh46VnKOqsbg="
        func replacing(_ c: Character) -> String {
            var chars = Array(payload); chars[60] = c; return String(chars)
        }
        let a = { (n: Int) in String(repeating: "A", count: n) }
        let vectors: [(String, Bool)] = [
            (payload, true),
            (String(payload.dropLast()), true), // a signer that drops the padding
            (payload + "\n", true),
            ("  " + payload + "\r\n", true),
            (a(131), false),
            (a(132), true),
            (a(133), false), // not a base64 length
            (a(87_472), true),
            (a(87_473), false),
            (replacing(" "), false),
            (replacing("-"), false), // URL-safe alphabet is not NIP-44
            (replacing("="), false),
            (payload + "=", false),
            (String(repeating: "meet at the old mill at 9, bring the key. ", count: 5), false),
        ]
        for (text, expected) in vectors {
            XCTAssertEqual(DraftEnvelope.looksEncrypted(text), expected, String(text.prefix(40)))
        }
    }

    /// Shaped like a payload (here unpadded) but it won't open: left out,
    /// never shown as text and never re-saved over the relay copy.
    func testUnreadablePayloadShapeIsNeverPlaintext() async {
        let unpadded = String(repeating: "QUJD", count: 40) + "QQ"
        let opened = await DraftEnvelope.open(content: unpadded, tags: [["d", "X"], ["k", "1"]],
                                              decrypt: { _ in throw URLError(.cannotDecodeContentData) })
        XCTAssertNil(opened)
    }

    /// One that can't be opened (another key, signer said no) is left out:
    /// its ciphertext is never shown as the draft's text.
    func testUnreadableCiphertextIsNeverShownAsText() async throws {
        let sealed = try await DraftEnvelope.seal(content: secret, tags: replyTags, updatedAt: saved,
                                                  encrypt: { Self.fakeEncrypt($0) })
        let failed = await DraftEnvelope.open(content: sealed.content, tags: sealed.tags,
                                              decrypt: { _ in throw URLError(.userAuthenticationRequired) })
        XCTAssertNil(failed)
        let notJSON = await DraftEnvelope.open(content: sealed.content, tags: sealed.tags, decrypt: { _ in "not json" })
        XCTAssertNil(notJSON)
    }

    /// A failed encryption fails the save: nothing goes out in its place.
    func testFailedEncryptionThrows() async {
        do {
            _ = try await DraftEnvelope.seal(content: secret, tags: replyTags, updatedAt: saved,
                                             encrypt: { _ in throw URLError(.userCancelledAuthentication) })
            XCTFail("sealed without encryption")
        } catch {}
    }
}

/// DraftService pulls in the whole app and can't be built here, so this
/// reads its source: the one kind 31234 it signs carries the sealed
/// envelope, encrypted to the author's own key, and what it fetches is opened
/// with DraftEnvelope, re-saving old plaintext drafts.
final class DraftServiceEncryptionWiringTests: XCTestCase {
    private func source() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("HavenApp/Services/DraftService.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testTheOnlyDraftSignedIsTheSealedOne() throws {
        let src = try source()
        let signs = src.components(separatedBy: "kind: 31234,").dropFirst()
        XCTAssertEqual(signs.count, 1, "one place signs a draft")
        XCTAssertTrue(signs.first?.hasPrefix(" content: sealed.content, tags: sealed.tags") == true)
        XCTAssertTrue(src.contains("DraftEnvelope.seal("))
        XCTAssertTrue(src.contains("encryptToSelf($0, me: me, nip04: false)"))
    }

    func testFetchedDraftsAreOpenedAndOldOnesResaved() throws {
        let src = try source()
        XCTAssertTrue(src.contains("DraftEnvelope.open("))
        XCTAssertTrue(src.contains("decryptToSelf($0, me: ownPubkey, nip04: false)"))
        let built = src.components(separatedBy: "relayDrafts.append(Draft(").dropFirst()
        XCTAssertEqual(built.count, 1, "one place builds a fetched draft")
        XCTAssertTrue(built.first?.contains("content: opened.content,") == true, "a fetched draft's content is never used unopened")
        XCTAssertTrue(src.contains("plaintextIds"))
    }

    /// Opening a draft can be a bunker round trip: one fetch at a time, and
    /// an event opened before (same id) isn't decrypted again.
    func testFetchesAreSingleFlightAndOpenedDraftsCached() throws {
        let src = try source()
        XCTAssertTrue(src.contains("if let running = fetchInFlight {"))
        XCTAssertTrue(src.contains("if fetchInFlight?.id == id { fetchInFlight = nil }"), "only the fetch that set the slot clears it")
        XCTAssertTrue(src.contains("var opened = openedDrafts[event.id]"))
        XCTAssertTrue(src.contains("openedDrafts = opens"))
    }
}
