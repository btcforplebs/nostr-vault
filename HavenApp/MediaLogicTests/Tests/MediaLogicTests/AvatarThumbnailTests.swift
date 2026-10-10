import XCTest
@testable import MediaLogic

final class AvatarThumbnailTests: XCTestCase {
    private func query(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
    }

    func testPublicPictureGoesThroughTheResizer() {
        let original = URL(string: "https://blossom.primal.net/6cbd7f7b.gif")!
        let thumb = AvatarThumbnail.url(for: original)
        XCTAssertEqual(thumb.host, "wsrv.nl")
        let q = query(thumb)
        XCTAssertEqual(q["url"], original.absoluteString)
        XCTAssertEqual(q["default"], original.absoluteString)
        XCTAssertEqual(q["w"], "256")
        XCTAssertEqual(q["h"], "256")
        XCTAssertEqual(q["output"], "webp")
    }

    /// The original's own query must stay inside `url`, not leak into the
    /// resizer's parameters.
    func testOriginalQueryStaysInsideTheURLValue() {
        let original = URL(string: "https://example.com/pic.png?w=2000&size=big&a=1")!
        let q = query(AvatarThumbnail.url(for: original))
        XCTAssertEqual(q["url"], original.absoluteString)
        XCTAssertEqual(q["w"], "256")
        XCTAssertNil(q["size"])
    }

    func testPlainHTTPIsResizedToo() {
        XCTAssertEqual(AvatarThumbnail.url(for: URL(string: "http://example.com/a.jpg")!).host, "wsrv.nl")
    }

    func testPrivateAndNonWebPicturesAreLeftAlone() {
        let untouched = [
            "data:image/png;base64,iVBORw0KGgo=",
            "file:///tmp/a.png",
            "http://localhost:4869/a.png",
            "http://127.0.0.1:3355/a.png",
            "https://192.168.1.20/a.png",
            "https://10.0.0.4/a.png",
            "https://172.20.1.1/a.png",
            "https://100.100.1.1/a.png",
            "http://vault.local/a.png",
            "http://abcdefghijklmnop.onion/a.png",
            "http://[::1]:3355/a.png",
            "https://wsrv.nl/?url=https%3A%2F%2Fexample.com%2Fa.png",
        ]
        for string in untouched {
            let url = URL(string: string)!
            XCTAssertEqual(AvatarThumbnail.url(for: url), url, string)
        }
    }

    func testPublicAddressesThatLookPrivateAreStillResized() {
        for string in ["https://172.32.0.1/a.png", "https://11.0.0.1/a.png", "https://192.169.0.1/a.png"] {
            XCTAssertEqual(AvatarThumbnail.url(for: URL(string: string)!).host, "wsrv.nl", string)
        }
    }
}
