import CoreImage
import XCTest
@testable import MediaLogic

/// The sign-in QR a signer on another device scans (NIP-46 nostrconnect://).
final class NostrConnectQRTests: XCTestCase {
    private let pk = String(repeating: "ab", count: 32)
    private let relays = ["wss://relay.powr.build", "wss://relay.damus.io"]

    private func items(_ uri: String) throws -> [URLQueryItem] {
        try XCTUnwrap(URLComponents(string: uri)?.queryItems)
    }

    func testRequestCarriesKeyRelaysSecretAndPerms() throws {
        let uri = try XCTUnwrap(NostrConnectURI.build(clientPubkey: pk, secret: "s3cret", relays: relays, callback: nil))
        XCTAssertTrue(uri.hasPrefix("nostrconnect://\(pk)?"))
        let q = try items(uri)
        XCTAssertEqual(q.filter { $0.name == "relay" }.map(\.value), relays)
        XCTAssertEqual(q.first { $0.name == "secret" }?.value, "s3cret")
        XCTAssertEqual(q.first { $0.name == "perms" }?.value, NostrConnectURI.perms)
    }

    /// A signer on ANOTHER device must not be told to open nostrvault:// —
    /// that app is not on its device. Only the same-phone hand-off sets it.
    func testCallbackOnlyWhenAsked() throws {
        let other = try XCTUnwrap(NostrConnectURI.build(clientPubkey: pk, secret: "s", relays: relays, callback: nil))
        XCTAssertNil(try items(other).first { $0.name == "callback" })
        let same = try XCTUnwrap(NostrConnectURI.build(clientPubkey: pk, secret: "s", relays: relays,
                                                       callback: "nostrvault://signer-return"))
        XCTAssertEqual(try items(same).first { $0.name == "callback" }?.value, "nostrvault://signer-return")
    }

    func testPlusIsEncoded() throws {
        let uri = try XCTUnwrap(NostrConnectURI.build(clientPubkey: pk, secret: "a+b", relays: relays, callback: nil))
        XCTAssertFalse(uri.contains("+"))
        XCTAssertEqual(try items(uri).first { $0.name == "secret" }?.value, "a+b")
    }

    /// The code on screen must read back as exactly the request we wait on.
    func testQRReadsBackAsTheRequest() throws {
        let uri = try XCTUnwrap(NostrConnectURI.build(clientPubkey: pk, secret: String(repeating: "c", count: 32),
                                                      relays: relays, callback: nil))
        let image = try XCTUnwrap(NostrConnectQR.cgImage(for: uri))
        XCTAssertGreaterThan(image.width, 200)
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                                options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        // Quiet zone: the generator's output has none, and a detector (like a
        // camera) needs one.
        let ci = CIImage(cgImage: image)
        let padded = ci.transformed(by: CGAffineTransform(translationX: 40, y: 40))
            .composited(over: CIImage(color: .white).cropped(to: ci.extent.insetBy(dx: -40, dy: -40).offsetBy(dx: 40, dy: 40)))
        let decoded = detector.features(in: padded).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        XCTAssertEqual(decoded, [uri])
    }

    /// The Mac can't open Clave, so it shows the code whichever button asked
    /// (Tron, #2478: the idle button passed .thisDevice and the Mac lost its QR).
    func testMacAlwaysShowsTheCode() {
        for requested in [NostrConnectTarget.thisDevice, .otherDevice] {
            let t = NostrConnectTarget.resolve(requested, canOpenSignerHere: false)
            XCTAssertEqual(t, .otherDevice)
            XCTAssertTrue(t.showsCode)
            XCTAssertFalse(t.includesCallback)
        }
    }

    func testPhoneKeepsWhatWasAsked() {
        let here = NostrConnectTarget.resolve(.thisDevice, canOpenSignerHere: true)
        XCTAssertEqual(here, .thisDevice)
        XCTAssertTrue(here.includesCallback)
        XCTAssertFalse(here.showsCode)
        let other = NostrConnectTarget.resolve(.otherDevice, canOpenSignerHere: true)
        XCTAssertTrue(other.showsCode)
        XCTAssertFalse(other.includesCallback)
    }
}
