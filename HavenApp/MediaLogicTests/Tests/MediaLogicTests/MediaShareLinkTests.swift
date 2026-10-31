import XCTest
@testable import MediaLogic

/// Copy link on a vault photo whose Mac relay address is an onion (user report
/// 2026-10-31: the link opened nothing).
final class MediaShareLinkTests: XCTestCase {
    private let sha = String(repeating: "a", count: 64)
    private let onion = "abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz56.onion"

    func testOnionMacRelayKeepsTheFilePathAndUsesHTTP() {
        for local in ["http://127.0.0.1:3355/\(sha)", "https://localhost:3355/\(sha)", "https://127.0.0.1:3355/\(sha).jpg"] {
            let link = MediaShareLink.external(for: URL(string: local)!, macRelayHTTPS: "https://\(onion)", mirrors: [])
            XCTAssertEqual(link.absoluteString, "http://\(onion)" + URL(string: local)!.path)
        }
    }

    func testOnionWithPortAndBasePath() {
        let link = MediaShareLink.external(for: URL(string: "http://127.0.0.1:3355/\(sha)?x=1")!,
                                           macRelayHTTPS: "https://\(onion):4869/vault/", mirrors: [])
        XCTAssertEqual(link.absoluteString, "http://\(onion):4869/vault/\(sha)?x=1")
    }

    func testOnionMirrorFallbackUsesHTTP() {
        let link = MediaShareLink.external(for: URL(string: "http://127.0.0.1:3355/\(sha)")!,
                                           macRelayHTTPS: "", mirrors: ["https://\(onion)", "https://b.example"])
        XCTAssertEqual(link.absoluteString, "http://\(onion)/\(sha)")
    }

    func testOnionRelayAddressItemUsesHTTP() {
        // relayURL set to the onion: the gallery already lists the file there.
        let link = MediaShareLink.external(for: URL(string: "https://\(onion)/\(sha).png")!, macRelayHTTPS: "", mirrors: [])
        XCTAssertEqual(link.absoluteString, "http://\(onion)/\(sha).png")
    }

    func testClearnetLinksAreUnchanged() {
        let local = URL(string: "http://127.0.0.1:3355/\(sha)")!
        XCTAssertEqual(MediaShareLink.external(for: local, macRelayHTTPS: "https://mac.example", mirrors: []).absoluteString,
                       "https://mac.example/\(sha)")
        XCTAssertEqual(MediaShareLink.external(for: local, macRelayHTTPS: "", mirrors: ["https://b.example/"]).absoluteString,
                       "https://b.example/\(sha)")
        XCTAssertEqual(MediaShareLink.external(for: local, macRelayHTTPS: "", mirrors: []), local)
        let remote = URL(string: "https://onion.example.com/\(sha)")!
        XCTAssertEqual(MediaShareLink.external(for: remote, macRelayHTTPS: "https://\(onion)", mirrors: []), remote)
    }
}
