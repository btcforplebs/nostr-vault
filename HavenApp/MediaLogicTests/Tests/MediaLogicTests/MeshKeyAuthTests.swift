import XCTest
@testable import MediaLogic

/// The mesh never uses the account key: the shapes the device's mesh key
/// signs (docs/MESH_COPY_V2_CONTRACT.md §2, §2.1) and the paired set the
/// engine is given.
final class MeshKeyAuthTests: XCTestCase {
    private let base = URL(string: "http://127.0.0.1:41234/secretingresstoken")!
    private let a = "npub1avault"
    private let sha = String(repeating: "ab", count: 32)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Copy start (27235)

    func testStartNamesTheVaultAndSignsOnlyThePath() throws {
        let tags = try XCTUnwrap(MeshKeyAuth.copyStartTags(base: base, receiver: a))
        XCTAssertEqual(tags, [["u", "http://127.0.0.1:41234/copy/v2/start"], ["method", "POST"], ["p", a]])
        XCTAssertFalse(tags.flatMap { $0 }.contains { $0.contains("secretingresstoken") })
        XCTAssertFalse(tags.contains { $0.first == "device" }, "the token is bound to the signer, no device tag")
    }

    func testStartWithoutAReceiverIsNotSigned() {
        XCTAssertNil(MeshKeyAuth.copyStartTags(base: base, receiver: " "))
    }

    // MARK: Blossom over the mesh (24242)

    func testOneVerbAnXPerBlobAPPerVaultAndFiveMinutesAtMost() throws {
        let other = String(repeating: "cd", count: 32)
        let tags = try XCTUnwrap(MeshKeyAuth.blossomTags(verb: .delete, sha256s: [sha, other, sha.uppercased()],
                                                          receivers: [a, "npub1mac", a], now: now, lifetime: 3600))
        XCTAssertEqual(tags.filter { $0.first == "t" }, [["t", "delete"]])
        XCTAssertEqual(tags.filter { $0.first == "x" }, [["x", sha], ["x", other]])
        XCTAssertEqual(tags.filter { $0.first == "p" }, [["p", a], ["p", "npub1mac"]])
        XCTAssertEqual(tags.last, ["expiration", "1800000300"], "a longer lifetime is cut to five minutes")
        XCTAssertFalse(tags.contains { $0.first == "server" }, "no server tag stand-in for p")
    }

    func testUploadCarriesItsSize() throws {
        let tags = try XCTUnwrap(MeshKeyAuth.blossomTags(verb: .upload, sha256s: [sha], receivers: [a], now: now, size: 42))
        XCTAssertEqual(tags, [["t", "upload"], ["x", sha], ["size", "42"], ["p", a], ["expiration", "1800000300"]])
    }

    func testShorterLifetimeKept() throws {
        let tags = try XCTUnwrap(MeshKeyAuth.blossomTags(verb: .get, sha256s: [sha], receivers: [a], now: now, lifetime: 60))
        XCTAssertEqual(tags.last, ["expiration", "1800000060"])
    }

    func testNoBlobOrNoVaultIsNotSigned() {
        XCTAssertNil(MeshKeyAuth.blossomTags(verb: .get, sha256s: [], receivers: [a], now: now))
        XCTAssertNil(MeshKeyAuth.blossomTags(verb: .get, sha256s: [sha], receivers: [" "], now: now))
    }

    // MARK: The paired set (SetMeshDevicesC)

    func testSetIsMyDevicesWithoutThisOneOnceEachRolesKept() throws {
        let devices = [MeshDevice(npub: "npub1phone", name: "Phone", role: .phone),
                       MeshDevice(npub: "npub1self", name: "Me", role: .mac),
                       MeshDevice(npub: "npub1box", name: "", role: .homeVault),
                       MeshDevice(npub: "npub1phone", name: "Again", role: .phone)]
        let json = try XCTUnwrap(MeshKeyAuth.deviceSet(selfNpub: "npub1self", devices: devices))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(obj["self"] as? String, "npub1self")
        let list = try XCTUnwrap(obj["devices"] as? [[String: String]])
        XCTAssertEqual(list, [["npub": "npub1phone", "role": "phone"], ["npub": "npub1box", "role": "homeVault"]])
    }

    func testNoDevicesGivesAnEmptySetNotNil() throws {
        let json = try XCTUnwrap(MeshKeyAuth.deviceSet(selfNpub: "npub1self", devices: []))
        XCTAssertTrue(json.contains("\"devices\":[]"))
    }

    func testNoMeshKeyNoSet() {
        XCTAssertNil(MeshKeyAuth.deviceSet(selfNpub: nil, devices: [MeshDevice(npub: "npub1x", name: "", role: .phone)]))
        XCTAssertNil(MeshKeyAuth.deviceSet(selfNpub: " ", devices: []))
    }

    // MARK: Owner form during the switch (TODO(mesh-key))

    func testOnlyAnAuthRefusalRetriesWithTheOwnerForm() {
        XCTAssertTrue(MeshKeyAuth.retriesWithOwnerForm(status: 401))
        XCTAssertTrue(MeshKeyAuth.retriesWithOwnerForm(status: 403))
        for status in [200, 400, 404, 409, 413, 500] {
            XCTAssertFalse(MeshKeyAuth.retriesWithOwnerForm(status: status), "\(status)")
        }
    }
}
