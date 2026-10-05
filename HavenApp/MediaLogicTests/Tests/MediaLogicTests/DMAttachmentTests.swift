import XCTest
@testable import MediaLogic

/// A DM photo is its Blossom URL inside an ordinary message, built the way
/// Android builds it, and shown as a photo rather than as the link.
final class DMAttachmentTests: XCTestCase {
    private let photo = URL(string: "https://blossom.primal.net/9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08.jpg")!

    // MARK: sending

    func testTextThenPhotoOnItsOwnLine() {
        XCTAssertEqual(DMAttachment.content(text: " look \n", imageURL: photo), "look\n\(photo.absoluteString)")
    }

    func testPhotoAloneIsJustTheURL() {
        XCTAssertEqual(DMAttachment.content(text: "  ", imageURL: photo), photo.absoluteString)
    }

    func testNoPhotoIsJustTheText() {
        XCTAssertEqual(DMAttachment.content(text: "hi ", imageURL: nil), "hi")
    }

    // MARK: showing

    func testSentMessageSplitsBackIntoTextAndPhoto() {
        let sent = DMAttachment.content(text: "look", imageURL: photo)
        let split = DMAttachment.split(sent)
        XCTAssertEqual(split.text, "look")
        XCTAssertEqual(split.images, [photo])
    }

    func testPhotoOnlyMessageHasNoText() {
        let split = DMAttachment.split(photo.absoluteString)
        XCTAssertEqual(split.text, "")
        XCTAssertEqual(split.images, [photo])
    }

    func testPhotoInsideASentenceKeepsTheWordsAroundIt() {
        let split = DMAttachment.split("before \(photo.absoluteString) after")
        XCTAssertEqual(split.text, "before after")
        XCTAssertEqual(split.images, [photo])
    }

    func testGifAndQueryStringCount() {
        let gif = "https://media.tenor.com/abc/cat.GIF?width=200"
        XCTAssertEqual(DMAttachment.split(gif).images.map(\.absoluteString), [gif])
    }

    func testRepeatsShowOnce() {
        XCTAssertEqual(DMAttachment.split("\(photo.absoluteString)\n\(photo.absoluteString)").images, [photo])
    }

    func testOtherLinksStayAsText() {
        for content in [
            "https://example.com/page",
            "https://example.com/clip.mp4",
            "ftp://example.com/a.jpg",
            "file:///private/a.jpg",
            "see example.com/a.jpg",
        ] {
            let split = DMAttachment.split(content)
            XCTAssertEqual(split.images, [], content)
            XCTAssertEqual(split.text, content, content)
        }
    }

    func testPlainTextIsUntouched() {
        let text = "  two\n\nlines  "
        XCTAssertEqual(DMAttachment.split(text).text, text)
    }
}
