import XCTest
@testable import MediaLogic

/// A3: "Delete from this device" only when another place proves a full copy,
/// asked just now; and the "removed here" list Auto-Mirror must skip.
final class DeleteHereGateTests: XCTestCase {
    private let sha = String(repeating: "ab", count: 32)
    private var blob: URL { URL(string: "https://cdn.example/\(sha)")! }
    private func ok206(_ total: String = "4096") -> DeleteHereGate.Answer {
        .init(status: 206, contentType: "image/jpeg", contentLength: "1", contentRange: "bytes 0-0/\(total)", finalURL: blob)
    }

    func testProofNeedsTheSameLength() {
        XCTAssertTrue(DeleteHereGate.proves(ok206(), sha256: sha, localSize: 4096))
        XCTAssertFalse(DeleteHereGate.proves(ok206("4095"), sha256: sha, localSize: 4096), "a different file under the hash")
        XCTAssertFalse(DeleteHereGate.proves(ok206("*"), sha256: sha, localSize: 4096))
        XCTAssertTrue(DeleteHereGate.proves(.init(status: 200, contentType: nil, contentLength: "4096", contentRange: nil, finalURL: blob), sha256: sha, localSize: 4096))
        XCTAssertFalse(DeleteHereGate.proves(.init(status: 200, contentType: nil, contentLength: nil, contentRange: nil, finalURL: blob), sha256: sha, localSize: 4096))
    }

    func testPlaceholdersAndRedirectsProveNothing() {
        var html = ok206(); html.contentType = "text/html; charset=utf-8"
        XCTAssertFalse(DeleteHereGate.proves(html, sha256: sha, localSize: 4096))
        var away = ok206(); away.finalURL = URL(string: "https://cdn.example/404.jpg")
        XCTAssertFalse(DeleteHereGate.proves(away, sha256: sha, localSize: 4096))
        for status in [404, 500, 302, 0] {
            var a = ok206(); a.status = status
            XCTAssertFalse(DeleteHereGate.proves(a, sha256: sha, localSize: 4096), "\(status)")
        }
    }

    func testOneProvenCopyIsEnough() {
        let d = DeleteHereGate.decide(answers: ["https://a.example": ok206(), "https://b.example": nil], sha256: sha, localSize: 4096)
        XCTAssertEqual(d, .allowed(holders: ["https://a.example"]))
    }

    func testFailsClosed() {
        guard case .refused = DeleteHereGate.decide(answers: [:], sha256: sha, localSize: 4096) else { return XCTFail("no servers") }
        guard case .refused = DeleteHereGate.decide(answers: ["https://a.example": nil, "https://b.example": nil], sha256: sha, localSize: 4096) else { return XCTFail("all unreachable") }
        var gone = ok206(); gone.status = 404
        guard case .refused = DeleteHereGate.decide(answers: ["https://a.example": gone, "https://b.example": nil], sha256: sha, localSize: 4096) else { return XCTFail("absent + unreachable") }
        guard case .refused = DeleteHereGate.decide(answers: ["https://a.example": ok206()], sha256: sha, localSize: 0) else { return XCTFail("no local file") }
    }

    func testThisDeviceNeverCountsButTheMacDoes() {
        let c = DeleteHereGate.candidates(["http://127.0.0.1:3355", "https://phone.tail.ts.net", "https://mac.tail.ts.net", "https://a.example", "https://a.example", "nonsense"],
                                          ownHosts: ["phone.tail.ts.net"])
        XCTAssertEqual(c, ["https://mac.tail.ts.net", "https://a.example"])
    }

    func testRemovedListSkipsAndClears() {
        let owner = String(repeating: "0a", count: 32), other = String(repeating: "0b", count: 32)
        var list = DeviceRemovedHashes()
        list.add(sha.uppercased(), owner: owner.uppercased())
        list.add("not-a-hash", owner: owner)
        list.add(sha, owner: "../etc")
        let kept = String(repeating: "cd", count: 32)
        XCTAssertTrue(list.contains(sha))
        XCTAssertEqual(list.byAccount, [owner: [sha]])
        XCTAssertEqual(list.keeping([kept, sha.uppercased()]), [kept])
        // Listed under two accounts; Save to Vault takes it off both.
        list.add(sha, owner: other)
        list.remove(sha.uppercased())
        XCTAssertEqual(list.keeping([kept, sha]), [kept, sha])
        XCTAssertTrue(list.byAccount.isEmpty)
        // One file in the relay data folder, the engine's working folder.
        XCTAssertEqual(DeviceRemovedHashes.fileURL(relayDataDir: URL(fileURLWithPath: "/db/", isDirectory: true)).path, "/db/removed_here.json")
    }

    /// The file Android and the engine (copyv2_removed_here.go) read and write.
    func testRemovedListSharesTheAndroidAndEngineShape() throws {
        let owner = String(repeating: "0a", count: 32)
        let android = Data(#"{"byAccount":{"\#(owner)":["\#(sha.uppercased())"]},"later":1}"#.utf8)
        let read = try JSONDecoder().decode(DeviceRemovedHashes.self, from: android)
        XCTAssertTrue(read.contains(sha))
        var mine = DeviceRemovedHashes()
        mine.add(sha, owner: owner)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(mine)) as? [String: [String: [String]]]
        XCTAssertEqual(json, ["byAccount": [owner: [sha]]])
    }

    /// S1: a cache's answer proves nothing; the probe always misses the cache.
    func testCachedAnswerProvesNothing() {
        var a = DeleteHereGate.Answer(status: 206, contentType: "image/jpeg", contentLength: "1",
                                      contentRange: "bytes 0-0/100", finalURL: nil)
        XCTAssertTrue(DeleteHereGate.proves(a, sha256: sha, localSize: 100))
        a.cacheStatus = "HIT"
        XCTAssertFalse(DeleteHereGate.proves(a, sha256: sha, localSize: 100))
        a.cacheStatus = "DYNAMIC"
        a.age = "0"
        XCTAssertTrue(DeleteHereGate.proves(a, sha256: sha, localSize: 100))
        a.age = "3600"
        XCTAssertFalse(DeleteHereGate.proves(a, sha256: sha, localSize: 100))

        let url = DeleteHereGate.probeURL(server: "http://a.example/media/", sha256: sha, nonce: "n1")
        XCTAssertEqual(url?.absoluteString, "https://a.example/media/\(sha)?nv=n1")
        XCTAssertNil(DeleteHereGate.probeURL(server: "nonsense", sha256: sha, nonce: "n"))
    }

    /// M1: the Mac's own tunnel domain is one of its own hosts.
    func testRelayHostFromSanitizedRelayURL() {
        XCTAssertEqual(DeleteHereGate.relayHost("Vault.Example.com/relay"), "vault.example.com")
        XCTAssertEqual(DeleteHereGate.relayHost("vault.example.com:8443"), "vault.example.com")
        XCTAssertNil(DeleteHereGate.relayHost(" "))
        let c = DeleteHereGate.candidates(["https://vault.example.com", "https://a.example"],
                                          ownHosts: [DeleteHereGate.relayHost("vault.example.com/relay")!])
        XCTAssertEqual(c, ["https://a.example"])
    }
}
