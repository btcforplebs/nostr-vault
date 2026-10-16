import XCTest
@testable import MediaLogic

/// Replies captured from the real servers on 2026-10-16, uploading a 64x64
/// PNG with a throwaway key.
final class BlossomUploadReplyTests: XCTestCase {
    private let sha = "8966a848cbdda8139b451594d1f2111ebdf71927c9ea369ed902c5d9d8e4612b"

    /// `PUT https://nostr.build/upload` and `PUT https://<name>.nostr.build/upload`:
    /// 200, text/html, the site's home page. Nothing was stored.
    func testNostrBuildWebsiteHomePageIsNotAnUpload() {
        let html = Data("\n\n<!DOCTYPE html>\n<html lang=\"en\">\n\n<head>\n\t<meta charset=\"utf-8\">".utf8)
        for server in ["https://nostr.build", "https://test.nostr.build"] {
            XCTAssertNil(BlossomUploadReply.hostedURL(body: html, server: URL(string: server)!, sha256: sha, onDeviceRelay: false), server)
        }
    }

    /// `PUT https://blossom.nostr.build/upload`: a BUD-02 descriptor whose
    /// link is on the uploader's blossom.band subdomain, not on the server
    /// that was asked. That link is the one to post.
    func testBlossomNostrBuildDescriptorGivesItsLink() {
        let link = "https://npub12q2nlqn9pj82y5mw4nx3vw79cv39x7rxtkh5e03y38nfjm9ww8qs4rukn7.blossom.band/\(sha).png"
        let body = Data("""
        {"url":"\(link)","size":186,"type":"image/png","sha256":"\(sha)","uploaded":1792141456,"nip94":[["url","\(link)"],["x","\(sha)"],["m","image/png"],["dim","64x64"]]}
        """.utf8)
        XCTAssertEqual(BlossomUploadReply.hostedURL(body: body, server: URL(string: "https://blossom.nostr.build")!, sha256: sha, onDeviceRelay: false)?.absoluteString, link)
    }

    /// khatru (this app's relay, the Mac relay) answers with url + sha256.
    func testKhatruDescriptor() {
        let body = Data(#"{"url":"http://192.168.1.20:3355/\#(sha).png","sha256":"\#(sha)","size":186,"type":"image/png","uploaded":1}"#.utf8)
        XCTAssertEqual(BlossomUploadReply.hostedURL(body: body, server: URL(string: "http://192.168.1.20:3355")!, sha256: sha, onDeviceRelay: false)?.absoluteString,
                       "http://192.168.1.20:3355/\(sha).png")
    }

    func testDescriptorForAnotherBlobIsNotThisUpload() {
        let other = String(repeating: "c", count: 64)
        let body = Data(#"{"url":"https://cdn.example/\#(other)","sha256":"\#(other)"}"#.utf8)
        XCTAssertNil(BlossomUploadReply.hostedURL(body: body, server: URL(string: "https://cdn.example")!, sha256: sha, onDeviceRelay: false))
    }

    func testDescriptorWithoutAWebLinkIsRejected() {
        for url in ["", "not a url", "javascript:alert(1)", "file:///etc/passwd"] {
            let body = Data(#"{"url":"\#(url)","sha256":"\#(sha)"}"#.utf8)
            XCTAssertNil(BlossomUploadReply.hostedURL(body: body, server: URL(string: "https://cdn.example")!, sha256: sha, onDeviceRelay: false), url)
        }
    }

    func testEmptyBodyFromAnOutsideServerIsNotAnUpload() {
        XCTAssertNil(BlossomUploadReply.hostedURL(body: Data(), server: URL(string: "https://cdn.example")!, sha256: sha, onDeviceRelay: false))
    }

    /// This device's own relay is addressed by hash whatever it answers.
    func testOnDeviceRelayIsAddressedByHash() {
        XCTAssertEqual(BlossomUploadReply.hostedURL(body: Data(), server: URL(string: "http://127.0.0.1:3355")!, sha256: sha, onDeviceRelay: true)?.absoluteString,
                       "http://127.0.0.1:3355/\(sha)")
    }
}
