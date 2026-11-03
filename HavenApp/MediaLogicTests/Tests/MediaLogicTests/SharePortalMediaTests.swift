import XCTest
@testable import MediaLogic

/// Share Portal lane B: picture/video post tags and the private copy's
/// sealed blob and record. The fixtures are read by Android's
/// SharePortalMediaFixtureTest too, so both platforms publish and seal the
/// same bytes.
final class SharePortalMediaTests: XCTestCase {

    private func fixture(_ name: String) throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/SharePortal"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func hex(_ s: String) throws -> Data { try XCTUnwrap(PrivateCopyRecord.unhex(s)) }

    // MARK: Picture / video post

    private func problemName(_ p: MediaPostShareTags.Problem) -> String {
        switch p {
        case .nothing: return "nothing"
        case .mixed: return "mixed"
        case .tooManyVideos: return "too_many_videos"
        case .tooManyPictures: return "too_many_pictures"
        case .notMedia: return "not_media"
        }
    }

    func testShapeFixtures() throws {
        let cases = try XCTUnwrap(fixture("media-post-cases")["shape"] as? [[String: Any]])
        for c in cases {
            let mimes = try XCTUnwrap(c["mimes"] as? [String])
            switch MediaPostShareTags.shape(mimes: mimes) {
            case .success(let shape):
                XCTAssertEqual(shape == .pictures ? "pictures" : "video", c["shape"] as? String, "\(mimes)")
            case .failure(let problem):
                XCTAssertEqual(problemName(problem), c["problem"] as? String, "\(mimes)")
            }
        }
    }

    func testNeedsJPEGFixtures() throws {
        let cases = try XCTUnwrap(fixture("media-post-cases")["needs_jpeg"] as? [[Any]])
        for c in cases {
            let mime = try XCTUnwrap(c[0] as? String)
            XCTAssertEqual(MediaPostShareTags.needsJPEG(mime), c[1] as? Bool, mime)
        }
    }

    func testEventFixtures() throws {
        let cases = try XCTUnwrap(fixture("media-post-cases")["events"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 4)
        for c in cases {
            let note = c["note"] as? String ?? "?"
            let shape: MediaPostShareTags.Shape = c["shape"] as? String == "video" ? .video : .pictures
            let media = try (c["media"] as? [[String: Any]] ?? []).map { m in
                MediaPostShareTags.Media(url: try XCTUnwrap(m["url"] as? String), mime: try XCTUnwrap(m["mime"] as? String),
                                         sha256: try XCTUnwrap(m["sha256"] as? String),
                                         width: (m["width"] as? NSNumber)?.intValue, height: (m["height"] as? NSNumber)?.intValue,
                                         bytes: (m["bytes"] as? NSNumber)?.intValue, duration: (m["duration"] as? NSNumber)?.doubleValue,
                                         alt: m["alt"] as? String)
            }
            let caption = c["caption"] as? String ?? ""
            XCTAssertEqual(MediaPostShareTags.kind(shape, media: media), c["kind"] as? Int, note)
            XCTAssertEqual(MediaPostShareTags.content(caption: caption), c["content"] as? String, note)
            let tags = MediaPostShareTags.tags(shape, media: media, title: c["title"] as? String ?? "", caption: caption,
                                               publishedAt: (c["published_at"] as? NSNumber)?.intValue ?? 0)
            XCTAssertEqual(tags, c["tags"] as? [[String]], note)
        }
    }

    func testDurationFormat() {
        XCTAssertEqual(MediaPostShareTags.format(7), "7")
        XCTAssertEqual(MediaPostShareTags.format(12.5), "12.5")
        XCTAssertEqual(MediaPostShareTags.format(3.14159), "3.142")
        XCTAssertEqual(MediaPostShareTags.format(0.05), "0.05")
    }

    // MARK: Private copy

    func testSealFixtures() throws {
        let cases = try XCTUnwrap(fixture("private-copy-cases")["seal"] as? [[String: Any]])
        for c in cases {
            let note = c["note"] as? String ?? "?"
            let sealed = try PrivateCopyRecord.seal(try hex(c["plain_hex"] as? String ?? ""),
                                                    key: try hex(c["key"] as? String ?? ""), nonce: try hex(c["nonce"] as? String ?? ""))
            XCTAssertEqual(PrivateCopyRecord.hex(sealed.blob), c["blob_hex"] as? String, note)
            XCTAssertEqual(sealed.x, c["x"] as? String, note)
            XCTAssertEqual(sealed.ox, c["ox"] as? String, note)
        }
    }

    func testRandomSealOpensAndNeverRepeats() throws {
        let plain = Data("a private page".utf8)
        let a = try PrivateCopyRecord.seal(plain), b = try PrivateCopyRecord.seal(plain)
        XCTAssertNotEqual(a.key, b.key)
        XCTAssertNotEqual(a.nonce, b.nonce)
        XCTAssertNotEqual(a.blob, b.blob)
        XCTAssertFalse(a.blob.range(of: plain) != nil, "the sealed blob must not hold the plain bytes")
        let record = PrivateCopyRecord.Record(name: "p.txt", mime: "text/plain", size: plain.count, x: a.x, ox: a.ox,
                                              key: a.key, nonce: a.nonce, source: nil, title: nil, savedAt: 1)
        XCTAssertEqual(try PrivateCopyRecord.open(a.blob, record: record), plain)
        XCTAssertEqual(PrivateCopyRecord.decode(PrivateCopyRecord.encode(record)), record)
    }

    func testRecordFixtures() throws {
        let cases = try XCTUnwrap(fixture("private-copy-cases")["records"] as? [[String: Any]])
        XCTAssertGreaterThan(cases.count, 10)
        for c in cases {
            let note = c["note"] as? String ?? "?"
            let decoded = PrivateCopyRecord.decode(c["json"] as? String ?? "")
            XCTAssertEqual(decoded != nil, c["valid"] as? Bool, note)
            if let decoded {
                XCTAssertEqual(PrivateCopyRecord.decode(PrivateCopyRecord.encode(decoded)), decoded, note)
            }
        }
    }

    func testOpenFixtures() throws {
        let f = try fixture("private-copy-cases")
        let record = try XCTUnwrap(PrivateCopyRecord.decode(try XCTUnwrap(f["open_record"] as? String)))
        for c in try XCTUnwrap(f["open"] as? [[String: Any]]) {
            let note = c["note"] as? String ?? "?"
            let blob = try hex(c["blob_hex"] as? String ?? "")
            if c["ok"] as? Bool == true {
                XCTAssertEqual(PrivateCopyRecord.hex(try PrivateCopyRecord.open(blob, record: record)), c["plain_hex"] as? String, note)
            } else {
                XCTAssertThrowsError(try PrivateCopyRecord.open(blob, record: record), note)
            }
        }
    }

    /// The right blob (hash matches) under a wrong key or nonce: the GCM
    /// tag must refuse it.
    func testOpenRefusesWrongKeyOrNonce() throws {
        let cases = try XCTUnwrap(fixture("private-copy-cases")["open_tag_fails"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 2)
        for c in cases {
            let note = c["note"] as? String ?? "?"
            let record = try XCTUnwrap(PrivateCopyRecord.decode(c["record"] as? String ?? ""), note)
            XCTAssertThrowsError(try PrivateCopyRecord.open(try hex(c["blob_hex"] as? String ?? ""), record: record), note) { error in
                XCTAssertFalse(error is PrivateCopyRecord.OpenError, "\(note): must fail in GCM, not on a hash check")
            }
        }
    }

    func testEventFixtures_privateCopy() throws {
        let f = try fixture("private-copy-cases")
        for c in try XCTUnwrap(f["events"] as? [[String: Any]]) {
            let id = PrivateCopyRecord.id(kind: c["kind"] as? Int ?? 0, tags: c["tags"] as? [[String]] ?? [])
            XCTAssertEqual(id, c["id"] as? String, c["note"] as? String ?? "?")
        }
        let tags = try XCTUnwrap(f["tags"] as? [String: Any])
        let id = try XCTUnwrap(tags["id"] as? String)
        XCTAssertEqual(PrivateCopyRecord.tags(id: id), tags["saved"] as? [[String]])
        XCTAssertEqual(PrivateCopyRecord.clearedTags(id: id), tags["cleared"] as? [[String]])
    }

    func testIsCiphertext() {
        XCTAssertFalse(PrivateCopyRecord.isCiphertext("{\"v\":1}"))
        XCTAssertFalse(PrivateCopyRecord.isCiphertext(""))
        XCTAssertTrue(PrivateCopyRecord.isCiphertext(Data([2] + [UInt8](repeating: 7, count: 120)).base64EncodedString()))
    }
}
