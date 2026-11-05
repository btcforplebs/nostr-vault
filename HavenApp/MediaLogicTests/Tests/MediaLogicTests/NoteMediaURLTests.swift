import XCTest
@testable import MediaLogic

final class NoteMediaURLTests: XCTestCase {
    func testRemoteHTTPSStaysHTTPS() {
        let url = URL(string: "https://blossom.primal.net/abc.jpg")!
        XCTAssertEqual(NoteMediaURL.normalized(url), url)
    }

    func testRemoteHTTPSWithPortStaysHTTPS() {
        let url = URL(string: "https://daytest.localtest.me:3392/abc.jpg")!
        XCTAssertEqual(NoteMediaURL.normalized(url), url)
    }

    func testThisDeviceGoesToHTTP() {
        XCTAssertEqual(NoteMediaURL.normalized(URL(string: "https://127.0.0.1:3355/abc.jpg")!),
                       URL(string: "http://127.0.0.1:3355/abc.jpg")!)
        XCTAssertEqual(NoteMediaURL.normalized(URL(string: "https://LOCALHOST/abc.jpg")!),
                       URL(string: "http://LOCALHOST/abc.jpg")!)
    }

    func testHostlessLinkIsDropped() {
        XCTAssertNil(NoteMediaURL.normalized(URL(string: "https:///abc.jpg")!))
    }

    func testPlainHTTPUnchanged() {
        let url = URL(string: "http://example.com/abc.jpg")!
        XCTAssertEqual(NoteMediaURL.normalized(url), url)
    }
}
