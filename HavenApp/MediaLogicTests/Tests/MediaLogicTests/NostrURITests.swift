import XCTest
@testable import MediaLogic

/// `nostr:` links from outside the app: which screen each one asks for, and
/// which ones the app refuses to act on.
final class NostrURITests: XCTestCase {
    private let npub = "npub180cvv07tjdrrgpa0j7j7tmnyl2yr6yr7l8j4s3evf6u64th6gkwsyjh6w6"
    private let note = "note1fntxtkcy9pjwucqwa9mddn7v03wwwsu9j330jj350nvhpky2tuaspk6nqc"

    func testProfileLinks() {
        XCTAssertEqual(NostrURI(string: "nostr:\(npub)"), .profile(npub))
        XCTAssertEqual(NostrURI(string: "nostr:nprofile1qqsabc"), .profile("nprofile1qqsabc"))
    }

    func testEventAndAddressLinks() {
        XCTAssertEqual(NostrURI(string: "nostr:\(note)"), .event(note))
        XCTAssertEqual(NostrURI(string: "nostr:nevent1qqsabc"), .event("nevent1qqsabc"))
        XCTAssertEqual(NostrURI(string: "nostr:naddr1qqsabc"), .address("naddr1qqsabc"))
    }

    func testURLFormIsReadTheSameWay() {
        XCTAssertEqual(NostrURI(url: URL(string: "nostr:\(npub)")!), .profile(npub))
    }

    func testSlashesQueryAndCaseAreTolerated() {
        XCTAssertEqual(NostrURI(string: "nostr://\(npub)"), .profile(npub))
        XCTAssertEqual(NostrURI(string: "NOSTR:\(npub.uppercased())"), .profile(npub))
        XCTAssertEqual(NostrURI(string: "nostr:\(note)?relay=wss://x"), .event(note))
        XCTAssertEqual(NostrURI(string: "  nostr:\(note)\n"), .event(note))
    }

    func testSecretKeysAndUnknownEntitiesAreRefused() {
        XCTAssertNil(NostrURI(string: "nostr:nsec1vl029mgpspedva04g90vltkh6fvh240zqtv9k0t9af8935ke9laqsnlfe5"))
        XCTAssertNil(NostrURI(string: "nostr:nrelay1qqsabc"))
        XCTAssertNil(NostrURI(string: "nostr:"))
        XCTAssertNil(NostrURI(string: "nostr:npub1 abc"))
    }

    func testOtherSchemesAreNotNostrLinks() {
        XCTAssertNil(NostrURI(string: "nostrvault://feed"))
        XCTAssertNil(NostrURI(string: "https://njump.me/\(npub)"))
        XCTAssertNil(NostrURI(string: npub))
    }
}
