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
        var list = DeviceRemovedHashes()
        list.add(sha.uppercased())
        list.add("not-a-hash")
        let other = String(repeating: "cd", count: 32)
        XCTAssertTrue(list.contains(sha))
        XCTAssertEqual(list.keeping([other, sha]), [other])
        list.remove(sha)
        XCTAssertEqual(list.keeping([other, sha]), [other, sha])
        XCTAssertEqual(list.removed.count, 0)
        XCTAssertNil(DeviceRemovedHashes.fileURL(owner: "../etc", vault: URL(fileURLWithPath: "/tmp/blossom/")))
        // Beside the vault folder, where the engine looks (haven-go removed_here.go).
        XCTAssertEqual(DeviceRemovedHashes.fileURL(owner: sha, vault: URL(fileURLWithPath: "/db/blossom/", isDirectory: true))?.path, "/db/removed_here/\(sha).json")
        XCTAssertEqual(DeviceRemovedHashes.fileURL(owner: sha.uppercased(), vault: URL(fileURLWithPath: "/db/blossom"))?.path, "/db/removed_here/\(sha).json")
    }
}
