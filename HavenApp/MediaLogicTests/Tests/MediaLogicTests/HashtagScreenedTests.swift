import XCTest
@testable import MediaLogic

/// New-user hashtag loop (Logen 2026-11-05,
/// RESEARCH/NV_NEW_USER_HASHTAG_LOOP_2026_11_05.md): hashtag views open
/// screened while Everyone is locked, not only with an empty web, and your
/// follows keep the top group while screened.
final class HashtagScreenedTests: XCTestCase {
    func testScreenedWhileUnderFiveFollowsEvenWithASmallWeb() {
        for n in 0..<TrustScopeLock.followsNeeded {
            XCTAssertTrue(TrustScopeLock.hashtagsScreened(everyoneIsOn: false, followCount: n, noWebYet: false),
                          "\(n) follows with a small web must open screened")
        }
        XCTAssertTrue(TrustScopeLock.hashtagsScreened(everyoneIsOn: false, followCount: 0, noWebYet: true))
    }

    func testFiveFollowsUseTheWebOfTrust() {
        XCTAssertFalse(TrustScopeLock.hashtagsScreened(everyoneIsOn: false, followCount: 5, noWebYet: false))
        XCTAssertFalse(TrustScopeLock.hashtagsScreened(everyoneIsOn: false, followCount: 300, noWebYet: false))
        // An empty web still opens screened, as before, however many follows.
        XCTAssertTrue(TrustScopeLock.hashtagsScreened(everyoneIsOn: false, followCount: 300, noWebYet: true))
    }

    func testEveryoneOnIsNeverScreened() {
        XCTAssertFalse(TrustScopeLock.hashtagsScreened(everyoneIsOn: true, followCount: 0, noWebYet: true))
        XCTAssertFalse(TrustScopeLock.hashtagsScreened(everyoneIsOn: true, followCount: 2, noWebYet: false))
    }

    func testFollowsKeepTheTopGroupWhenScreened() {
        let follows: Set<String> = ["friend"]
        XCTAssertTrue(TopicFeedFilter.inFollowsGroup(author: "friend", follows: follows, trustScoped: false, screened: true),
                      "a friend must not be screened out with the strangers")
        XCTAssertTrue(TopicFeedFilter.inFollowsGroup(author: "friend", follows: follows, trustScoped: true, screened: false))
        XCTAssertFalse(TopicFeedFilter.inFollowsGroup(author: "stranger", follows: follows, trustScoped: false, screened: true))
        // Everyone: one list by time.
        XCTAssertFalse(TopicFeedFilter.inFollowsGroup(author: "friend", follows: follows, trustScoped: false, screened: false))
    }
}
