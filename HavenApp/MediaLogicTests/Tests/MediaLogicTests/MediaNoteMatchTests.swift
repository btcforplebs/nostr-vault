import XCTest
@testable import MediaLogic

/// The Vault media viewer's swipe up: every note on the vault that uses a file.
final class MediaNoteMatchTests: XCTestCase {
    private let sha = String(repeating: "ab", count: 32)
    private var url: URL { URL(string: "https://blossom.example/\(sha).jpg")! }

    private func note(_ id: String, kind: Int = 1, at: Int64, content: String = "", tags: [[String]] = []) -> MediaNoteMatch.Note {
        MediaNoteMatch.Note(id: id, kind: kind, createdAt: at, content: content, tags: tags)
    }

    func testTheHashIsReadFromABlossomNameWithOrWithoutItsExtension() {
        XCTAssertEqual(MediaNoteMatch.sha256(of: url), sha)
        XCTAssertEqual(MediaNoteMatch.sha256(of: URL(string: "https://b.example/\(sha.uppercased())")!), sha)
        XCTAssertNil(MediaNoteMatch.sha256(of: URL(string: "https://img.example/photo.jpg")!))
    }

    func testEveryNoteNamingTheFileByURLHashOrImetaNewestFirst() {
        let other = URL(string: "https://mirror.example/\(sha).png")!.absoluteString
        let found = MediaNoteMatch.notes(using: url, in: [
            note("byURL", at: 10, content: "look \(url.absoluteString)"),
            note("byMirror", at: 30, content: "same file elsewhere \(other)"),
            note("byImeta", kind: 20, at: 20, tags: [["imeta", "url \(other)", "x \(sha)"]]),
            note("byX", kind: 1063, at: 25, tags: [["x", sha]]),
            note("unrelated", at: 40, content: "https://img.example/other.jpg"),
            note("reaction", kind: 7, at: 50, content: url.absoluteString),
            note("byURL", at: 10, content: "look \(url.absoluteString)"),
        ])
        XCTAssertEqual(found.map(\.id), ["byMirror", "byX", "byImeta", "byURL"])
    }

    func testAFileWithoutAHashMatchesByItsURLOnly() {
        let plain = URL(string: "https://img.example/photo.jpg")!
        let found = MediaNoteMatch.notes(using: plain, in: [
            note("yes", at: 1, content: "https://IMG.example/photo.jpg"),
            note("no", at: 2, content: "https://img.example/photo2.jpeg"),
        ])
        XCTAssertEqual(found.map(\.id), ["yes"])
    }
}
