import XCTest
@testable import MediaLogic

final class QueuedMediaPostTests: XCTestCase {

    private let hashA = String(repeating: "a", count: 64)
    private let hashB = String(repeating: "b", count: 64)

    private func post(
        body: String = "gm #nostr",
        media: [QueuedMediaPost.Media],
        quoteSuffix: String? = nil,
        baseTags: [[String]] = [["p", "abc"]]
    ) -> QueuedMediaPost {
        QueuedMediaPost(accountNpub: "npub1me", body: body, media: media, quoteSuffix: quoteSuffix, baseTags: baseTags)
    }

    // MARK: - Readiness

    func testNotAssembledWhileAnyAttachmentIsOnlyOnThisDevice() {
        let queued = post(media: [
            .init(sha256: hashA, mimeType: "image/jpeg", url: "https://mac.example/\(hashA)"),
            .init(sha256: hashB, mimeType: "image/png", url: nil),
        ])
        XCTAssertFalse(queued.isReady)
        XCTAssertEqual(queued.pendingMedia.map(\.sha256), [hashB])
        XCTAssertNil(queued.assembled())
    }

    // MARK: - Same note as a direct post

    /// The queue must publish exactly what ComposeView.postNote() would have
    /// published had the server answered first time: content lines in
    /// attachment order, quote reference last, base tags then `t` then `imeta`.
    func testAssemblesTheSameNoteAsTheDirectPath() {
        let urlA = "https://mac.example/\(hashA).jpg"
        let urlB = "https://blossom.example/\(hashB)"
        let quote = "\nnostr:nevent1quoted"
        var queued = post(
            body: "gm #Nostr",
            media: [
                .init(sha256: hashA, mimeType: "image/jpeg", url: nil, pixelWidth: 800, pixelHeight: 600, alt: "a cat", byteCount: 1234),
                .init(sha256: hashB, mimeType: "image/png", url: urlB),
            ],
            quoteSuffix: quote,
            baseTags: [["e", "root", "", "root"], ["q", "quoted"]]
        )
        queued.media[0].url = urlA

        // What postNote() builds.
        let directContent = "gm #Nostr" + "\n\(urlA)" + "\n\(urlB)" + quote
        var directTags: [[String]] = [["e", "root", "", "root"], ["q", "quoted"]]
        directTags += NoteTagging.hashtagTags(in: directContent)
        directTags += NoteTagging.imetaTags(for: [
            .init(url: urlA, mimeType: "image/jpeg", sha256: hashA, pixelWidth: 800, pixelHeight: 600, alt: "a cat", byteCount: 1234),
            .init(url: urlB, mimeType: "image/png", sha256: hashB),
        ])

        let assembled = queued.assembled()
        XCTAssertEqual(assembled?.content, directContent)
        XCTAssertEqual(assembled?.tags, directTags)
        XCTAssertEqual(assembled?.tags.filter { $0.first == "imeta" }.count, 2)
        XCTAssertEqual(assembled?.tags.filter { $0.first == "t" }, [["t", "nostr"]])
    }

    func testMediaOnlyPostHasNoTextLine() {
        let url = "https://mac.example/\(hashA)"
        let queued = post(body: "", media: [.init(sha256: hashA, mimeType: "image/jpeg", url: url)], baseTags: [])
        XCTAssertEqual(queued.assembled()?.content, "\n\(url)")
    }

    // MARK: - Survives a relaunch

    func testRoundTripsThroughJSON() throws {
        let queued = post(
            media: [.init(sha256: hashA, mimeType: "video/mp4", url: nil, pixelWidth: 1920, pixelHeight: 1080, alt: nil, byteCount: 99)],
            quoteSuffix: "\nnostr:nevent1x"
        )
        let decoded = try JSONDecoder().decode(QueuedMediaPost.self, from: JSONEncoder().encode(queued))
        XCTAssertEqual(decoded, queued)
    }

    // MARK: - Wording

    func testQueuedMessageNamesTheMacVault() {
        XCTAssertEqual(
            MediaUploadOutcomeMessage.queued(hosts: ["mac.ts.net"], macHost: "mac.ts.net"),
            "Saved on this device. Your post will send itself as soon as your Mac vault answers."
        )
        XCTAssertTrue(
            MediaUploadOutcomeMessage.queued(hosts: ["mac.ts.net", "blossom.example"], macHost: "mac.ts.net")
                .contains("your Mac vault or another media server")
        )
    }

    func testQueuedMessageNamesASingleOtherServer() {
        XCTAssertTrue(
            MediaUploadOutcomeMessage.queued(hosts: ["blossom.example"], macHost: nil)
                .contains("as soon as blossom.example answers")
        )
        XCTAssertTrue(
            MediaUploadOutcomeMessage.queued(hosts: ["a.example", "b.example"], macHost: "mac.ts.net")
                .contains("one of your media servers")
        )
    }

    func testNoMessageBlamesTheConnection() {
        for message in [
            MediaUploadOutcomeMessage.noOutsideServer,
            MediaUploadOutcomeMessage.notSavedOnDevice,
            MediaUploadOutcomeMessage.queued(hosts: ["x"], macHost: nil),
        ] {
            XCTAssertFalse(message.localizedCaseInsensitiveContains("connection"), message)
        }
    }
}
