import XCTest
@testable import MediaLogic

/// Share profile's address, nostrvault.app/p/<npub>: what is written, and
/// what reads back as a profile when it is scanned, pasted or opened.
final class ProfileShareLinkTests: XCTestCase {
    private let npub = "npub180cvv07tjdrrgpa0j7j7tmnyl2yr6yr7l8j4s3evf6u64th6gkwsyjh6w6"

    func testWritesTheSiteAddressForAnNpub() {
        XCTAssertEqual(ProfileShareLink.url(npub: npub)?.absoluteString, "https://nostrvault.app/p/\(npub)")
        XCTAssertEqual(ProfileShareLink.url(npub: " \(npub.uppercased())\n")?.absoluteString, "https://nostrvault.app/p/\(npub)")
    }

    func testNeverWritesAnythingButAnNpub() {
        XCTAssertNil(ProfileShareLink.url(npub: "nsec1vl029mgpspedva04g90vltkh6fvh240zqtv9k0t9af8935ke9laqsnlfe5"))
        XCTAssertNil(ProfileShareLink.url(npub: String(repeating: "a", count: 64)))
        XCTAssertNil(ProfileShareLink.url(npub: "npub1"))
        XCTAssertNil(ProfileShareLink.url(npub: "npub1 abc"))
    }

    func testReadsTheAddressBack() {
        XCTAssertEqual(ProfileShareLink.profileID(from: "https://nostrvault.app/p/\(npub)"), npub)
        XCTAssertEqual(ProfileShareLink.profileID(from: "https://www.nostrvault.app/p/\(npub)/"), npub)
        XCTAssertEqual(ProfileShareLink.profileID(from: "  https://NostrVault.app/p/\(npub.uppercased())?ref=qr\n"), npub)
        XCTAssertEqual(ProfileShareLink.profileID(from: "https://nostrvault.app/p/nprofile1qqsabc"), "nprofile1qqsabc")
    }

    func testReadsTheAppLinkBack() {
        XCTAssertEqual(ProfileShareLink.appURL(npub: npub)?.absoluteString, "nostrvault://p/\(npub)")
        XCTAssertEqual(ProfileShareLink.profileID(from: "nostrvault://p/\(npub)"), npub)
        XCTAssertEqual(NostrURI(string: "nostrvault://p/\(npub)"), .profile(npub))
        XCTAssertNil(ProfileShareLink.profileID(from: "nostrvault://feed"))
        XCTAssertNil(ProfileShareLink.profileID(from: "nostrvault://x/\(npub)"))
        XCTAssertNil(ProfileShareLink.profileID(from: "nostrvault://p/\(npub)/more"))
    }

    func testOtherAddressesAreNotProfiles() {
        XCTAssertNil(ProfileShareLink.profileID(from: "https://nostrvault.app/thread/\(npub)"))
        XCTAssertNil(ProfileShareLink.profileID(from: "https://nostrvault.app/p/"))
        XCTAssertNil(ProfileShareLink.profileID(from: "https://nostrvault.app/p/\(npub)/notes"))
        XCTAssertNil(ProfileShareLink.profileID(from: "https://evil.example/p/\(npub)"))
        XCTAssertNil(ProfileShareLink.profileID(from: "https://nostrvault.app.evil.example/p/\(npub)"))
        XCTAssertNil(ProfileShareLink.profileID(from: "https://nostrvault.app/p/nsec1vl029mgpspedva04g90vltkh6fvh240zqtv9k0t9af8935ke9laqsnlfe5"))
        XCTAssertNil(ProfileShareLink.profileID(from: "ftp://nostrvault.app/p/\(npub)"))
        XCTAssertNil(ProfileShareLink.profileID(from: npub))
    }

    func testNostrURIOpensTheAddressAsAProfile() {
        XCTAssertEqual(NostrURI(string: "https://nostrvault.app/p/\(npub)"), .profile(npub))
        XCTAssertEqual(NostrURI(url: URL(string: "https://nostrvault.app/p/\(npub)")!), .profile(npub))
        XCTAssertNil(NostrURI(string: "https://nostrvault.app/thread/nevent1qqsabc"))
    }
}
