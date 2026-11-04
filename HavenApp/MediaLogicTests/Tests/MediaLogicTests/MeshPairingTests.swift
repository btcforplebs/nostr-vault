import CryptoKit
import XCTest
@testable import MediaLogic

/// Two-scan pairing against the fixtures Kotlin and the web read too
/// (Fixtures/MeshPairing, made by reference.py; docs/MESH_PAIRING_CONTRACT.md).
final class MeshPairingTests: XCTestCase {
    private func fixture(_ name: String) throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/MeshPairing"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func role(_ s: Any?) throws -> MeshDeviceRole {
        try XCTUnwrap(MeshDeviceRole(rawValue: s as? String ?? ""))
    }

    func testParse() throws {
        let cases = try XCTUnwrap(try fixture("payload-cases")["parse"] as? [[String: Any]])
        XCTAssertGreaterThan(cases.count, 30)
        for c in cases {
            let name = c["name"] as? String ?? "?"
            let got = MeshPairing.parse(c["uri"] as? String ?? "", ownMesh: c["own"] as? String)
            let expect = try XCTUnwrap(c["expect"] as? [String: Any])
            if let refusal = expect["refusal"] as? String {
                XCTAssertEqual(got, .failure(.init(try XCTUnwrap(MeshPairing.Refusal(rawValue: refusal)))), name)
                continue
            }
            let p = try XCTUnwrap(expect["payload"] as? [String: Any])
            guard case .success(let payload) = got else { XCTFail("\(name): \(got)"); continue }
            XCTAssertEqual(payload.mesh, p["mesh"] as? String, name)
            XCTAssertEqual(payload.meshHex, p["mesh_hex"] as? String, name)
            XCTAssertEqual(payload.name, p["name"] as? String, name)
            XCTAssertEqual(payload.role, try role(p["role"]), name)
            XCTAssertEqual(payload.owner, p["owner"] as? String, name)
            XCTAssertEqual(payload.ownerHex, p["owner_hex"] as? String, name)
            if let s = p["secret"] as? String { XCTAssertEqual(payload.code, .secret(s), name) }
            if let e = p["echo"] as? String { XCTAssertEqual(payload.code, .echo(e, bSecret: p["b_secret"] as? String ?? ""), name) }
        }
    }

    func testBuild() throws {
        let fx = try fixture("payload-cases")
        let rule = try XCTUnwrap(fx["rule"] as? [String: Any])
        XCTAssertEqual(rule["name_max"] as? Int, MeshPairing.nameMax)
        XCTAssertEqual(rule["roles"] as? [String], MeshPairing.wireRoles.map(\.rawValue))
        for c in try XCTUnwrap(fx["build"] as? [[String: Any]]) {
            let a = try XCTUnwrap(c["args"] as? [String: Any])
            let code: MeshPairing.Code = (a["s"] as? String).map { .secret($0) } ?? .echo(a["e"] as? String ?? "", bSecret: a["b"] as? String ?? "")
            let uri = MeshPairing.build(mesh: a["m"] as? String ?? "", name: a["n"] as? String ?? "", role: try role(a["r"]),
                                        owner: a["o"] as? String ?? "", code: code)
            XCTAssertEqual(uri, c["expect"] as? String, c["name"] as? String ?? "?")
            guard case .success = MeshPairing.parse(uri, ownMesh: nil) else { return XCTFail("built code must read back") }
        }
    }

    func testOwnerAndRole() throws {
        let fx = try fixture("payload-cases")
        for c in try XCTUnwrap(fx["owner"] as? [[String: Any]]) {
            let got = MeshPairing.ownerCheck(owner: c["owner"] as? String ?? "", active: c["active"] as? String,
                                             accounts: c["accounts"] as? [String] ?? [])
            let s: String
            switch got {
            case .ok: s = "ok"
            case .switchTo(let n): s = "switchTo:" + n
            case .otherOwner: s = "otherOwner"
            }
            XCTAssertEqual(s, c["expect"] as? String, c["name"] as? String ?? "?")
        }
        for c in try XCTUnwrap(fx["role"] as? [[String: Any]]) {
            let existing = try (c["existing"] as? [[String: Any]] ?? []).map {
                MeshDevice(npub: $0["npub"] as? String ?? "", name: "", role: try role($0["role"]))
            }
            let got = MeshPairing.roleCheck(npub: c["npub"] as? String ?? "", role: try role(c["role"]), existing: existing)
            let s: String
            switch got {
            case .add: s = "add"
            case .alreadyLinked: s = "alreadyLinked"
            case .refuseOtherRole(let r): s = "refuseOtherRole:" + r.rawValue
            }
            XCTAssertEqual(s, c["expect"] as? String, c["name"] as? String ?? "?")
        }
    }

    func testTexts() throws {
        for c in try XCTUnwrap(try fixture("payload-cases")["texts"] as? [[String: Any]]) {
            let expect = c["expect"] as? String
            switch c["kind"] as? String {
            case "confirm":
                XCTAssertEqual(MeshPairing.roleConfirmText(role: try role(c["role"]), name: c["name"] as? String ?? "",
                                                           setup: c["setup"] as? Bool ?? false), expect)
            case "short":
                XCTAssertEqual(MeshPairing.shortAddress(c["npub"] as? String ?? ""), expect)
            default:
                let code = c["code"] as? String ?? ""
                let got: String
                switch code {
                case "otherOwner": got = MeshPairing.otherOwnerText
                case "alreadyLinked": got = MeshPairing.alreadyLinkedText
                case "expired": got = MeshPairing.expiredText
                case "abort": got = MeshPairing.abortText
                case "switchTo": got = MeshPairing.switchToText(accountName: c["account_name"] as? String ?? "")
                case "refuseOtherRole": got = MeshPairing.otherRoleText(try role(c["role"]))
                default: got = MeshPairing.text(try XCTUnwrap(MeshPairing.Refusal(rawValue: code), code))
                }
                XCTAssertEqual(got, expect, code)
            }
        }
    }

    func testHelloAndAckBuilders() throws {
        let fx = try fixture("hello-cases")
        let rule = try XCTUnwrap(fx["rule"] as? [String: Any])
        XCTAssertEqual(rule["hello_kind"] as? Int, MeshPairing.helloKind)
        XCTAssertEqual(rule["code_lifetime"] as? Int, MeshPairing.codeLifetime)
        XCTAssertEqual(rule["scan_window"] as? Int, MeshPairing.scanWindow)
        XCTAssertEqual(rule["ack_window"] as? Int, MeshPairing.ackWindow)
        XCTAssertEqual(rule["hello_skew"] as? Int, MeshPairing.helloSkew)
        for b in try XCTUnwrap(fx["builders"] as? [[String: Any]]) {
            let a = try XCTUnwrap(b["args"] as? [String: Any])
            let got = b["kind"] as? String == "ack"
                ? MeshPairing.ackJSON(digest: a["d"] as? String ?? "", words: a["w"] as? Bool ?? false)
                : MeshPairing.helloJSON(secret: a["s"] as? String ?? "", name: a["n"] as? String ?? "", role: try role(a["r"]),
                                        owner: a["o"] as? String ?? "", time: a["t"] as? Int ?? 0)
            XCTAssertEqual(got, b["expect"] as? String)
        }
    }

    func testSessions() throws {
        let cases = try XCTUnwrap(try fixture("hello-cases")["cases"] as? [[String: Any]])
        XCTAssertGreaterThan(cases.count, 30)
        for c in cases {
            let name = c["name"] as? String ?? "?"
            let steps = try XCTUnwrap(c["steps"] as? [[String: Any]])
            if c["side"] as? String == "joiner" {
                let qrA = MeshPairing.parse(c["qr_a"] as? String ?? "", ownMesh: nil)
                guard case .success(let a) = qrA else { XCTFail(name); continue }
                var j = try XCTUnwrap(MeshPairingJoiner(qrA: a, ownMeshHex: c["own_mesh"] as? String ?? "",
                                                        ownSecret: c["own_secret"] as? String ?? "",
                                                        scannedAt: c["scanned_at"] as? Int ?? 0), name)
                for (i, st) in steps.enumerated() {
                    let got = st["op"] as? String == "words" ? j.confirmWords(now: st["now"] as? Int ?? 0)
                        : j.receiveAck(senderHex: st["sender"] as? String ?? "", content: st["content"] as? String ?? "",
                                       now: st["now"] as? Int ?? 0)
                    XCTAssertEqual(code(got), st["expect"] as? String, "\(name) step \(i)")
                }
                continue
            }
            var s = MeshPairingSession(secret: c["secret"] as? String ?? "", createdAt: c["created_at"] as? Int ?? 0,
                                       ownMeshHex: c["own_mesh"] as? String ?? "", active: c["active"] as? String,
                                       accounts: c["accounts"] as? [String] ?? [])
            for (i, st) in steps.enumerated() {
                let now = st["now"] as? Int ?? 0
                let got: MeshPairingSession.Outcome
                switch st["op"] as? String {
                case "hello": got = s.receiveHello(senderHex: st["sender"] as? String ?? "", content: st["content"] as? String ?? "", now: now)
                case "qr": got = s.acceptSecondQR(st["uri"] as? String ?? "", now: now)
                default: got = s.acceptWithoutScan(now: now)
                }
                XCTAssertEqual(code(got), st["expect"] as? String, "\(name) step \(i)")
                if let ack = st["ack"] as? String { XCTAssertEqual(s.ack, ack, "\(name) step \(i) ack") }
            }
        }
    }

    func testConfirmCarriesTheHellosDevice() throws {
        let cases = try XCTUnwrap(try fixture("hello-cases")["cases"] as? [[String: Any]])
        let c = try XCTUnwrap(cases.first { ($0["name"] as? String)?.hasPrefix("happy path") == true })
        var s = MeshPairingSession(secret: c["secret"] as? String ?? "", createdAt: c["created_at"] as? Int ?? 0,
                                   ownMeshHex: c["own_mesh"] as? String ?? "", active: c["active"] as? String,
                                   accounts: c["accounts"] as? [String] ?? [])
        let steps = try XCTUnwrap(c["steps"] as? [[String: Any]])
        _ = s.receiveHello(senderHex: steps[0]["sender"] as? String ?? "", content: steps[0]["content"] as? String ?? "",
                           now: steps[0]["now"] as? Int ?? 0)
        let got = s.acceptSecondQR(steps[1]["uri"] as? String ?? "", now: steps[1]["now"] as? Int ?? 0)
        guard case .confirm(let device) = got else { return XCTFail("\(got)") }
        XCTAssertEqual(MeshPairing.npubHex(device.npub), steps[0]["sender"] as? String)
        XCTAssertEqual(device.name, "Logen's iPhone")
        XCTAssertEqual(device.role, .phone)
    }

    func testCheckWordsAndAckDigest() throws {
        let fx = try fixture("checkwords-cases")
        let rule = try XCTUnwrap(fx["rule"] as? [String: Any])
        let url = try XCTUnwrap(Bundle.module.url(forResource: "words", withExtension: "txt", subdirectory: "Fixtures/MeshPairing"))
        let listFile = try Data(contentsOf: url)
        XCTAssertEqual(SHA256.hash(data: listFile).map { String(format: "%02x", $0) }.joined(), rule["list_sha256"] as? String)
        XCTAssertEqual(MeshPairingWords.list, String(decoding: listFile, as: UTF8.self).split(separator: "\n").map(String.init))
        XCTAssertEqual(MeshPairingWords.list.count, 2048)
        for c in try XCTUnwrap(fx["cases"] as? [[String: Any]]) {
            let a = c["a"] as? String ?? "", b = c["b"] as? String ?? "", s = c["secret"] as? String ?? ""
            XCTAssertEqual(MeshPairing.checkWords(aHex: a, bHex: b, secret: s), c["words"] as? [String])
            XCTAssertEqual(MeshPairing.ackDigest(secret: s, aHex: a, bHex: b), c["ack_digest"] as? String)
            XCTAssertEqual(MeshPairing.ackDigest(secret: s, bSecret: c["b_secret"] as? String, aHex: a, bHex: b),
                           c["ack_digest_scan"] as? String)
        }
    }

    func testNewSecretIsFreshAndReadable() {
        let a = MeshPairing.newSecret(), b = MeshPairing.newSecret()
        XCTAssertNotEqual(a, b)
        XCTAssertNotNil(MeshPairing.secretBytes(a))
        XCTAssertEqual(a.count, 22)
    }

    private func code(_ o: MeshPairingSession.Outcome) -> String {
        switch o {
        case .camera: return "camera"
        case .ignoreDuplicate: return "ignoreDuplicate"
        case .abort: return "abort"
        case .expired: return "expired"
        case .ignore(let r): return "ignore:" + r.rawValue
        case .refuse(let r): return "refuse:" + r.rawValue
        case .confirm: return "confirm"
        case .reject(let r): return "reject:" + r.rawValue
        case .unreadable(let r): return "refuse:" + r.rawValue
        }
    }

    private func code(_ o: MeshPairingJoiner.Outcome) -> String {
        switch o {
        case .linked: return "linked"
        case .waitWords: return "waitWords"
        case .waitAck: return "waitAck"
        case .ignoreDuplicate: return "ignoreDuplicate"
        case .expired: return "expired"
        case .ignore(let r): return "ignore:" + r.rawValue
        }
    }
}
