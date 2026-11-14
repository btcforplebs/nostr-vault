import XCTest
@testable import MediaLogic

/// DM photos as NIP-17 kind 15 locked files (DM privacy, Tron 2026-11-14), checked against the shared vectors
/// (DM_FILE_VECTORS.json, the same file Android and web read) and against bytes the web's own code made
/// (DM_FILE_INTEROP.json, generated from web-vault PR #2075): the apps must open what the web sends and send what
/// the web opens, byte for byte.
final class DMFileTests: XCTestCase {
    private func json(_ name: String) throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/DMFile"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
    private func bytes(_ hex: Any?) throws -> Data { try XCTUnwrap(DMFile.unhex(try XCTUnwrap(hex as? String))) }
    private func tag(_ tags: [[String]], _ name: String) -> String? { tags.first { $0.first == name }?[1] }

    // MARK: shared vectors (Tara, D0)

    func testEverySharedVectorOpensOrIsRefusedAsExpected() throws {
        let vectors = try XCTUnwrap(json("DM_FILE_VECTORS")["vectors"] as? [[String: Any]])
        XCTAssertEqual(vectors.count, 10)
        for v in vectors {
            let id = v["id"] as? String ?? "?"
            let expect = try XCTUnwrap(v["expect"] as? String)
            let rumor = try XCTUnwrap(v["rumor"] as? [String: Any])
            let tags = try XCTUnwrap(rumor["tags"] as? [[String]])
            let content = try XCTUnwrap(rumor["content"] as? String)
            let cipher = try bytes(v["ciphertext_hex"])
            // The kind 15 rumor as the inbox keeps it.
            let kept = try XCTUnwrap(DMFile.messageContent(kind: 15, content: content, tags: tags), id)
            switch expect {
            case "reject_algorithm", "reject_key":
                // Not encrypted the way this reads: kept as the bare link, never given a key.
                XCTAssertEqual(kept, content, id)
                XCTAssertNil(DMFile.parseLink(kept), id)
                continue
            default:
                break
            }
            let sealed = try XCTUnwrap(DMFile.parseLink(kept), id)
            XCTAssertEqual(sealed.url.absoluteString, content, id)
            XCTAssertEqual(sealed.mime, tag(tags, "file-type"), id)
            let result = Result { try DMFile.decrypt(cipher, sealed) }
            switch expect {
            case "ok": XCTAssertEqual(try result.get(), try bytes(v["plaintext_hex"]), id)
            case "reject_x": XCTAssertThrowsError(try result.get(), id) { XCTAssertEqual($0 as? DMFile.Refusal, .x, id) }
            case "reject_decrypt": XCTAssertThrowsError(try result.get(), id) { XCTAssertEqual($0 as? DMFile.Refusal, .decrypt, id) }
            case "reject_ox": XCTAssertThrowsError(try result.get(), id) { XCTAssertEqual($0 as? DMFile.Refusal, .ox, id) }
            default: XCTFail("unknown expect \(expect) in \(id)")
            }
        }
    }

    func testOurEncryptionOfAVectorIsItsCiphertext() throws {
        let v = try XCTUnwrap((json("DM_FILE_VECTORS")["vectors"] as? [[String: Any]])?.first { $0["id"] as? String == "png-12-byte-nonce" })
        let enc = try DMFile.encrypt(try bytes(v["plaintext_hex"]), key: try bytes(v["key"]), nonce: try bytes(v["nonce"]))
        XCTAssertEqual(enc.cipher, try bytes(v["ciphertext_hex"]))
        XCTAssertEqual(enc.x, v["x"] as? String)
        XCTAssertEqual(enc.ox, v["ox"] as? String)
    }

    // MARK: the web's send (PR #2075)

    func testWeSendWhatTheWebSendsForTheSameKeyAndNonce() throws {
        let s = try XCTUnwrap(json("DM_FILE_INTEROP")["kind15_send"] as? [String: Any])
        let enc = try DMFile.encrypt(try bytes(s["plaintext_hex"]), key: try bytes(s["key"]), nonce: try bytes(s["nonce"]))
        XCTAssertEqual(enc.cipher, try bytes(s["ciphertext_hex"]))
        XCTAssertEqual(DMFile.tags(enc, mime: "image/gif"), s["rumor_file_tags"] as? [[String]])
        XCTAssertEqual(s["rumor_kind"] as? Int, 15)
    }

    func testWeOpenTheWebsKind15AndItsOwnLocalLink() throws {
        let s = try XCTUnwrap(json("DM_FILE_INTEROP")["kind15_send"] as? [String: Any])
        let cipher = try bytes(s["ciphertext_hex"]), plain = try bytes(s["plaintext_hex"])
        let kept = try XCTUnwrap(DMFile.messageContent(kind: 15, content: try XCTUnwrap(s["rumor_content"] as? String),
                                                       tags: try XCTUnwrap(s["rumor_file_tags"] as? [[String]])))
        XCTAssertEqual(try DMFile.decrypt(cipher, try XCTUnwrap(DMFile.parseLink(kept))), plain)
        // The web's own "#nv-dm=" link (no ox in it) parses here too.
        let webLink = try XCTUnwrap(s["web_local_link"] as? String)
        let fromWeb = try XCTUnwrap(DMFile.parseLink(webLink))
        XCTAssertEqual(fromWeb.mime, "image/gif")
        XCTAssertNil(fromWeb.ox)
        XCTAssertEqual(try DMFile.decrypt(cipher, fromWeb), plain)
    }

    // MARK: our own round trip and the rumor kinds

    func testFreshKeysRoundTripAndAreNeverReused() throws {
        let plain = Data("a photo".utf8)
        let a = try DMFile.encrypt(plain), b = try DMFile.encrypt(plain)
        XCTAssertNotEqual(a.key, b.key)
        XCTAssertNotEqual(a.nonce, b.nonce)
        XCTAssertEqual(a.nonce.count, 24, "12-byte nonce, as the web sends")
        XCTAssertNotEqual(a.cipher.prefix(plain.count), plain)
        XCTAssertEqual(try DMFile.decrypt(a.cipher, key: a.key, nonce: a.nonce, x: a.x, ox: a.ox), plain)
    }

    func testRumorKinds() {
        XCTAssertEqual(DMFile.messageContent(kind: 14, content: "hi", tags: []), "hi")
        XCTAssertNil(DMFile.messageContent(kind: 7, content: "+", tags: []))
        XCTAssertNil(DMFile.messageContent(kind: 15, content: "not a url", tags: []), "a kind 15 with no https file is no message")
        XCTAssertNil(DMFile.messageContent(kind: 15, content: "http://plain.example/a.jpg", tags: []))
        XCTAssertEqual(DMFile.messageContent(kind: 15, content: "https://a.example/b.jpg", tags: []), "https://a.example/b.jpg",
                       "an unencrypted kind 15 shows as an old photo link")
    }

    func testOurLocalLinkRoundTripsAndSurvivesTheAttachmentSplit() throws {
        let enc = try DMFile.encrypt(Data("x".utf8))
        let url = URL(string: "https://nostr.download/\(enc.x)")!
        let link = DMFile.link(DMFile.Sealed(url: url, key: enc.key, nonce: enc.nonce, x: enc.x, ox: enc.ox, mime: "image/jpeg"))
        let parsed = try XCTUnwrap(DMFile.parseLink(link))
        XCTAssertEqual(parsed, DMFile.Sealed(url: url, key: enc.key, nonce: enc.nonce, x: enc.x, ox: enc.ox, mime: "image/jpeg"))
        // The same rumor read back (our self-copy) gives the same link: the optimistic bubble is replaced, not doubled.
        let back = DMFile.messageContent(kind: 15, content: url.absoluteString, tags: DMFile.tags(enc, mime: "image/jpeg"))
        XCTAssertEqual(back, link)
        let split = DMAttachment.split("look\n\(link)", withVideos: true)
        XCTAssertEqual(split.text, "look")
        XCTAssertEqual(split.images.map(\.absoluteString), [link])
        XCTAssertFalse(split.text.contains(enc.key))
    }

    func testPreviewsNeverShowTheKey() throws {
        let enc = try DMFile.encrypt(Data("x".utf8))
        let link = DMFile.link(DMFile.Sealed(url: URL(string: "https://h.example/\(enc.x)")!, key: enc.key, nonce: enc.nonce, x: enc.x, ox: nil, mime: "image/png"))
        XCTAssertEqual(DMFile.displayText(link), "Photo")
        XCTAssertFalse(DMFile.displayText("see\n\(link)").contains(enc.key))
        XCTAssertEqual(DMFile.displayText("plain https://a.example/b.jpg"), "plain https://a.example/b.jpg")
    }

    func testBrokenLinksDontParse() {
        XCTAssertNil(DMFile.parseLink("https://h.example/a#nv-dm=!!"))
        XCTAssertNil(DMFile.parseLink("http://h.example/a#nv-dm=e30"))
        XCTAssertNil(DMFile.parseLink("https://h.example/a#nv-dm=e30"), "{} has no key")
    }
}

/// A DM GIF goes up as its frames only: the same bytes the web's stripGif makes for the same GIF.
final class GIFStripTests: XCTestCase {
    private func interop() throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "DM_FILE_INTEROP", withExtension: "json", subdirectory: "Fixtures/DMFile"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    func testSameBytesAsTheWeb() throws {
        let cases = try XCTUnwrap(interop()["gif_strip"] as? [[String: String]])
        XCTAssertEqual(cases.count, 3)
        for c in cases {
            let input = try XCTUnwrap(DMFile.unhex(c["input_hex"]!)), want = try XCTUnwrap(DMFile.unhex(c["output_hex"]!))
            XCTAssertEqual(try GIFStrip.strip(input), want, c["id"]!)
            XCTAssertEqual(try GIFStrip.strip(want), want, "a clean GIF comes out the same: \(c["id"]!)")
        }
    }

    func testSecretsAreGoneAndFramesStay() throws {
        let c = try XCTUnwrap((interop()["gif_strip"] as? [[String: String]])?.first { $0["id"] == "dirty-animated" })
        let out = try GIFStrip.strip(try XCTUnwrap(DMFile.unhex(c["input_hex"]!)))
        let text = String(decoding: out, as: UTF8.self)
        for secret in ["made by Alice", "xmpmeta", "ICCRGBG1", "secret caption", "8BIM", "trailing junk"] {
            XCTAssertFalse(text.contains(secret), secret)
        }
        XCTAssertTrue(text.contains("NETSCAPE2.0"), "the loop count stays")
        XCTAssertEqual(out.last, 0x3b)
    }

    func testABrokenGIFIsRefused() throws {
        let refused = try XCTUnwrap(interop()["gif_refused_hex"] as? [String: String])
        XCTAssertEqual(refused.count, 3)
        for (id, hex) in refused {
            XCTAssertThrowsError(try GIFStrip.strip(try XCTUnwrap(DMFile.unhex(hex))), id)
        }
    }
}

extension DMFileTests {
    /// Tron #2076 item 5: the same server hash under another key or nonce is another file on this device.
    func testOpenedCopyIsNamedByHashKeyAndNonce() {
        let url = URL(string: "https://example.com/" + String(repeating: "a", count: 64))!
        let x = String(repeating: "a", count: 64)
        let k1 = String(repeating: "1", count: 64), k2 = String(repeating: "2", count: 64)
        let n1 = String(repeating: "3", count: 24), n2 = String(repeating: "4", count: 24)
        let base = DMFile.Sealed(url: url, key: k1, nonce: n1, x: x, ox: nil, mime: "image/jpeg")
        let otherKey = DMFile.Sealed(url: url, key: k2, nonce: n1, x: x, ox: nil, mime: "image/jpeg")
        let otherNonce = DMFile.Sealed(url: url, key: k1, nonce: n2, x: x, ox: nil, mime: "image/jpeg")
        XCTAssertNotEqual(DMFile.openedName(base), DMFile.openedName(otherKey))
        XCTAssertNotEqual(DMFile.openedName(base), DMFile.openedName(otherNonce))
        XCTAssertEqual(DMFile.openedName(base), DMFile.openedName(base))
        XCTAssertNotEqual(DMFile.openedName(base), x, "never the bare hash")
    }
}
