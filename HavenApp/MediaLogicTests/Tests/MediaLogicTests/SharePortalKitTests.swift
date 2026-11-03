import XCTest
@testable import MediaLogic

final class SharePortalKitTests: XCTestCase {

    // MARK: Limits

    func testSourceFieldsAreCappedNotRejected() {
        let long = String(repeating: "a", count: NVShareLimits.selection + 50)
        let intent = NVShareIntent(action: .highlight, source: .init(url: "https://x.com", selection: long))
        XCTAssertEqual(intent.source.selection?.utf16.count, NVShareLimits.selection)
        let decoded = NVShareIntent.decode(NVShareIntent(id: "a", action: .highlight).encoded())
        XCTAssertNotNil(decoded)
    }

    func testCapDoesNotSplitASurrogatePair() {
        let s = String(repeating: "a", count: 9) + "😀"   // 9 + 2 UTF-16 units
        XCTAssertEqual(NVShareLimits.cap(s, 10), String(repeating: "a", count: 9))
        XCTAssertEqual(NVShareLimits.cap(s, 11), s)
    }

    func testTooManyFilesRejects() throws {
        let id = "abc"
        let files = (0..<21).map { ["name": "f\($0).jpg", "mime": "image/jpeg", "path": "files/abc/f\($0).jpg", "bytes": 1] as [String: Any] }
        let json: [String: Any] = ["v": 1, "id": id, "created_at": 1, "action": "upload", "files": files]
        XCTAssertNil(NVShareIntent.decode(try JSONSerialization.data(withJSONObject: json)))
        let twenty: [String: Any] = ["v": 1, "id": id, "created_at": 1, "action": "upload", "files": Array(files.prefix(20))]
        XCTAssertNotNil(NVShareIntent.decode(try JSONSerialization.data(withJSONObject: twenty)))
    }

    func testBooleanIsNotAVersion() throws {
        let json: [String: Any] = ["v": true, "id": "a", "created_at": 1, "action": "upload"]
        XCTAssertNil(NVShareIntent.decode(try JSONSerialization.data(withJSONObject: json)))
    }

    func testStale() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        XCTAssertFalse(NVShareIntent(createdAt: 1_000_000_000 - 3600, action: .highlight).isStale(now: now))
        XCTAssertTrue(NVShareIntent(createdAt: 1_000_000_000 - 8 * 24 * 3600, action: .highlight).isStale(now: now))
    }

    // MARK: Queue

    private func tempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testAddThenClaimOnceMovesIntentAndFiles() throws {
        let root = try tempRoot()
        let queue = NVShareQueue(root: root.appendingPathComponent("q"))
        let claimed = NVShareQueue(root: root.appendingPathComponent("c"))
        let src = root.appendingPathComponent("page.pdf")
        try Data("pdf".utf8).write(to: src)

        let written = try queue.add(NVShareIntent(id: "one", createdAt: 5, action: .privateCopy),
                                    attachments: [.init(source: src, name: "page.pdf", mime: "application/pdf"),
                                                  .init(source: src, name: "page.pdf", mime: "application/pdf")])
        XCTAssertEqual(written.files.map(\.name), ["page.pdf", "page-2.pdf"])
        XCTAssertEqual(written.files.first?.bytes, 3)
        XCTAssertTrue(queue.hasPending)

        let got = queue.claimAll(into: claimed)
        XCTAssertEqual(got.map(\.id), ["one"])
        XCTAssertFalse(queue.hasPending)
        XCTAssertTrue(queue.claimAll(into: claimed).isEmpty, "a second claim finds nothing")
        let file = try XCTUnwrap(got.first?.files.first)
        XCTAssertNotNil(claimed.fileURL(for: file, of: got[0]))
        XCTAssertEqual(claimed.all().map(\.id), ["one"])

        claimed.remove(id: "one")
        XCTAssertTrue(claimed.all().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: claimed.filesFolder(for: "one").path))
    }

    func testPartialAndBrokenIntentsAreNeverReturned() throws {
        let root = try tempRoot()
        let queue = NVShareQueue(root: root.appendingPathComponent("q"))
        let claimed = NVShareQueue(root: root.appendingPathComponent("c"))
        try FileManager.default.createDirectory(at: queue.root, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: queue.root.appendingPathComponent(".partial-x.json"))
        try Data("not json".utf8).write(to: queue.root.appendingPathComponent("bad.json"))
        // Valid JSON whose id does not match its file name.
        try NVShareIntent(id: "other", action: .highlight).encoded().write(to: queue.root.appendingPathComponent("liar.json"))
        try FileManager.default.createDirectory(at: queue.filesFolder(for: "bad"), withIntermediateDirectories: true)

        XCTAssertTrue(queue.claimAll(into: claimed).isEmpty)
        XCTAssertTrue(claimed.all().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: queue.filesFolder(for: "bad").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: queue.root.appendingPathComponent(".partial-x.json").path),
                      "a write in progress is left alone")
    }

    func testAttachmentNamesCannotEscapeTheFolder() throws {
        let root = try tempRoot()
        let queue = NVShareQueue(root: root.appendingPathComponent("q"))
        let src = root.appendingPathComponent("x")
        try Data("x".utf8).write(to: src)
        let written = try queue.add(NVShareIntent(id: "n", action: .dm),
                                    attachments: [.init(source: src, name: "../../evil", mime: "text/plain"),
                                                  .init(source: src, name: ".hidden", mime: "text/plain")])
        XCTAssertEqual(written.files.map(\.name), ["-..-evil", "hidden"])
        for f in written.files { XCTAssertTrue(NVShareLimits.isValidFileName(f.name)) }
        XCTAssertNotNil(NVShareIntent.decode(written.encoded()))
    }

    func testBadIDIsRefusedOnWrite() throws {
        let root = try tempRoot()
        let queue = NVShareQueue(root: root)
        XCTAssertThrowsError(try queue.add(NVShareIntent(id: "../x", action: .dm)))
    }

    // MARK: Accounts snapshot

    func testAccountsSnapshotRoundTripDropsNonNpubs() throws {
        let root = try tempRoot()
        NVShareAccountsSnapshot(active: "npub1a", accounts: [
            .init(npub: "npub1a", name: "A", picture: nil),
            .init(npub: "nsec1oops", name: "B", picture: nil),
        ]).write(root: root)
        let read = try XCTUnwrap(NVShareAccountsSnapshot.read(root: root))
        XCTAssertEqual(read.accounts.map(\.npub), ["npub1a"])
        XCTAssertEqual(read.active, "npub1a")
    }

    // MARK: Availability

    func testOfferedKeepsTheClassifierOrder() {
        XCTAssertEqual(NVShareActionAvailability.offered([.pay, .bookmark, .highlight, .profile, .dm, .upload]),
                       [.pay, .bookmark, .highlight, .profile, .dm, .upload])
    }

    /// Every lane is in (A, B, C, D): the sheet offers all 13 actions. A
    /// new action must be added here on purpose.
    func testEveryActionIsReady() {
        XCTAssertEqual(NVShareActionAvailability.ready, Set(NVShareAction.allCases))
        XCTAssertEqual(NVShareActionAvailability.offered([.mediaPost, .privateCopy, .profile, .bookmark]),
                       [.mediaPost, .privateCopy, .profile, .bookmark])
    }

    // MARK: Highlight tags

    func testHighlightTagsFromAPage() {
        let tags = HighlightShareTags.tags(url: "https://example.com/a", passage: " keep ", comment: " nice ")
        XCTAssertEqual(tags, [
            ["r", "https://example.com/a", "source"],
            ["comment", "nice"],
            ["alt", "Highlight: \"keep\""],
        ])
    }

    /// Tron, PR 1610: text deleted from the passage must not ride along.
    func testDeletedSelectionTextIsNotPublished() {
        let tags = HighlightShareTags.tags(url: "https://e.com", passage: "the quick brown fox jumps.", comment: "")
        XCTAssertFalse(tags.joined().contains { $0.contains("4471") })
        XCTAssertFalse(tags.contains { $0.first == "context" })
    }

    func testCanonicalMustBeOnThePagesHost() {
        XCTAssertTrue(NVShareClassifier.sameHost("https://example.com/canon", "https://EXAMPLE.com/a?x=1"))
        XCTAssertFalse(NVShareClassifier.sameHost("https://evil.com/x", "https://example.com/a"))
        XCTAssertFalse(NVShareClassifier.sameHost("https://example.com.evil.com/", "https://example.com/"))
        XCTAssertFalse(NVShareClassifier.sameHost("https://example.com/", nil))
    }

    func testHighlightTagsUntrimmedNoCommentNoURL() {
        XCTAssertEqual(HighlightShareTags.tags(url: nil, passage: "all of it", comment: ""),
                       [["alt", "Highlight: \"all of it\""]])
        XCTAssertEqual(HighlightShareTags.tags(url: "javascript:x", passage: "p", comment: ""),
                       [["alt", "Highlight: \"p\""]])
    }
}
