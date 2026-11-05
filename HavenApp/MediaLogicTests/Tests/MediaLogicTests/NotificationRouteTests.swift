import XCTest
@testable import MediaLogic

/// A privately blocked author never notifies, whatever the type.
final class NotificationRouteTests: XCTestCase {
    private let blocked = "ab" + String(repeating: "0", count: 62)

    func testFollowFromABlockedPersonIsDropped() {
        XCTAssertEqual(NotificationRoute.route(type: "follow", author: blocked, blocked: [blocked]), .drop)
    }

    func testDMFromABlockedPersonIsDropped() {
        XCTAssertEqual(NotificationRoute.route(type: "dm", author: blocked, blocked: [blocked]), .drop)
    }

    func testBlockMatchesUppercaseAuthor() {
        XCTAssertEqual(NotificationRoute.route(type: "follow", author: blocked.uppercased(), blocked: [blocked]), .drop)
    }

    func testUnblockedRoutesByType() {
        XCTAssertEqual(NotificationRoute.route(type: "follow", author: "cd", blocked: [blocked]), .follow)
        XCTAssertEqual(NotificationRoute.route(type: "giftwrap", author: "", blocked: [blocked]), .dm)
        XCTAssertEqual(NotificationRoute.route(type: "reply", author: "cd", blocked: [blocked]), .note)
    }
}
