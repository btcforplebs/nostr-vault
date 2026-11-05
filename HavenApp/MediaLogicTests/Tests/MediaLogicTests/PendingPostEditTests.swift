import XCTest
@testable import MediaLogic

/// Edit on a pending quote post: the composer adds `\nnostr:<nevent>` on
/// Post, so the text handed back must not already carry it, and its hosted
/// photos come back as attachments.
final class PendingPostEditTests: XCTestCase {
    private let nevent = "nevent1qqsabc"

    func testQuoteLineIsTakenOffForEdit() {
        let published = "Look at this\nnostr:\(nevent)"
        XCTAssertEqual(PendingPostEdit.editableText(published, quotedNevent: nevent), "Look at this")
    }

    /// Edited and posted again: one quote line, not two.
    func testEditThenPostCarriesOneQuoteLine() {
        let published = "Look at this\nnostr:\(nevent)"
        let reposted = PendingPostEdit.editableText(published, quotedNevent: nevent) + "\nnostr:\(nevent)"
        XCTAssertEqual(reposted.components(separatedBy: "nostr:\(nevent)").count - 1, 1)
    }

    func testTextWithoutAQuoteIsUnchanged() {
        XCTAssertEqual(PendingPostEdit.editableText("Hello", quotedNevent: nil), "Hello")
        XCTAssertEqual(PendingPostEdit.editableText("Hello", quotedNevent: nevent), "Hello")
    }

    /// The same reference typed into the body, not at the end, stays.
    func testReferenceInTheBodyStays() {
        let text = "nostr:\(nevent) is great"
        XCTAssertEqual(PendingPostEdit.editableText(text, quotedNevent: nevent), text)
    }

    func testHostedPhotosComeBackFromImeta() {
        let url = "https://blossom.example/abc.jpg"
        let tags = [["p", "x"],
                    ["imeta", "url \(url)", "m image/jpeg", "dim 10x10", "alt A cat on a mat"],
                    ["imeta", "url https://gone.example/x.png", "m image/png"]]
        let media = PendingPostEdit.media(fromTags: tags, in: "Hi\n\(url)")
        XCTAssertEqual(media, [PendingPostEdit.Media(url: url, mimeType: "image/jpeg", alt: "A cat on a mat")])
    }

    func testDuplicateImetaComesBackOnce() {
        let url = "https://blossom.example/abc.jpg"
        let tags = [["imeta", "url \(url)"], ["imeta", "url \(url)", "m image/jpeg"]]
        XCTAssertEqual(PendingPostEdit.media(fromTags: tags, in: url).count, 1)
    }
}
