import XCTest
@testable import MediaLogic

final class SearchRecommendationsTests: XCTestCase {
    // MARK: People

    func testPeopleMostVouchedFirstSkippingFollowsSelfAndBlocked() {
        let vouches = ["a": 5, "b": 9, "me": 20, "f": 30, "x": 12, "c": 5]
        let people = SearchRecommendations.people(vouches: vouches, following: ["f"],
                                                  owner: "me", blocked: ["x"])
        XCTAssertEqual(people.map(\.pubkey), ["b", "a", "c"])
        XCTAssertEqual(people.first?.vouches, 9)
    }

    func testPeopleNeedTwoVouches() {
        let people = SearchRecommendations.people(vouches: ["a": 1, "b": 2], following: [],
                                                  owner: "me", blocked: [])
        XCTAssertEqual(people.map(\.pubkey), ["b"])
    }

    func testPeopleCapped() {
        let vouches = Dictionary(uniqueKeysWithValues: (0..<20).map { ("p\($0)", 3) })
        XCTAssertEqual(SearchRecommendations.people(vouches: vouches, following: [], owner: "me",
                                                    blocked: [], limit: 4).count, 4)
    }

    // MARK: Notes

    private func note(_ id: String, _ pubkey: String, _ tags: [String], _ t: TimeInterval = 0)
        -> SearchRecommendations.Candidate {
        .init(id: id, pubkey: pubkey, tags: tags.map { ["t", $0] }, createdAt: Date(timeIntervalSince1970: t))
    }

    func testNotesNeedAnInterestAndRankByHits() {
        let notes = [
            note("1", "a", ["art"]),
            note("2", "b", ["art", "Music"]),
            note("3", "c", ["cooking"]),
        ]
        let ids = SearchRecommendations.notes(notes, interests: ["art", "#music"], following: [],
                                              vouches: [:], owner: "me", blocked: [])
        XCTAssertEqual(ids, ["2", "1"])
    }

    func testNotesPreferFollowsThenVouchesThenNewest() {
        let notes = [
            note("stranger", "s", ["art"], 300),
            note("vouched", "v", ["art"], 100),
            note("followed", "f", ["art"], 0),
            note("newer-stranger", "n", ["art"], 400),
        ]
        let ids = SearchRecommendations.notes(notes, interests: ["art"], following: ["f"],
                                              vouches: ["v": 4], owner: "me", blocked: [])
        XCTAssertEqual(ids, ["followed", "vouched", "newer-stranger", "stranger"])
    }

    func testNotesOnePerAuthorAndSkipOwnAndBlocked() {
        let notes = [
            note("a1", "a", ["art"], 2),
            note("a2", "a", ["art"], 1),
            note("mine", "me", ["art"]),
            note("bad", "x", ["art"]),
        ]
        let ids = SearchRecommendations.notes(notes, interests: ["art"], following: [],
                                              vouches: [:], owner: "me", blocked: ["x"])
        XCTAssertEqual(ids, ["a1"])
    }

    func testNoInterestsNoNotes() {
        XCTAssertEqual(SearchRecommendations.notes([note("1", "a", ["art"])], interests: [],
                                                   following: [], vouches: [:], owner: "me",
                                                   blocked: []), [])
    }

    func testNotesSkipSeen() {
        let ids = SearchRecommendations.notes([note("1", "a", ["art"]), note("2", "b", ["art"])],
                                              interests: ["art"], following: [], vouches: [:],
                                              owner: "me", blocked: [], seen: ["1"])
        XCTAssertEqual(ids, ["2"])
    }

    // MARK: Interests

    func testInterestsFollowedFirstThenEngagedByUse() {
        let engaged: [[[String]]] = [
            [["t", "Music"]], [["t", "music"]], [["t", "art"]], [["t", "Bitcoin"]],
        ]
        XCTAssertEqual(SearchRecommendations.interests(followed: ["#Bitcoin", "nostr"], engaged: engaged),
                       ["bitcoin", "nostr", "music", "art"])
    }

    func testInterestsCapped() {
        let engaged: [[[String]]] = (0..<20).map { [["t", "t\($0)"]] }
        XCTAssertEqual(SearchRecommendations.interests(followed: ["a", "b"], engaged: engaged, limit: 4).count, 4)
    }
}
