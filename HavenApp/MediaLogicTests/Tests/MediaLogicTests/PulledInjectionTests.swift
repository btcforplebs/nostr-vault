import XCTest
@testable import MediaLogic

/// The injection clients mark their connection so the relay stores what was
/// pulled from relays without blasting it back (haven-go isPulledConn).
final class PulledInjectionTests: XCTestCase {
    func testMarksTheRelayAddress() throws {
        for base in ["ws://127.0.0.1:3355", "wss://localhost:3355", "ws://127.0.0.1:3355/"] {
            let url = try XCTUnwrap(PulledInjection.url(base))
            let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            XCTAssertEqual(parts.queryItems, [URLQueryItem(name: "pulled", value: "1")], base)
            XCTAssertEqual(parts.port, 3355, base)
            // Still the outbox: the relay routes by path, and "/inbox" etc. stay off.
            XCTAssertTrue(parts.path == "" || parts.path == "/", base)
        }
    }

    func testKeepsOtherQueryItemsAndDoesNotRepeat() throws {
        let url = try XCTUnwrap(PulledInjection.url("ws://127.0.0.1:3355/?a=b&pulled=0"))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items, [URLQueryItem(name: "a", value: "b"), URLQueryItem(name: "pulled", value: "1")])
    }
}
