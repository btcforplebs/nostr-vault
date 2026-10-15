import XCTest
@testable import MediaLogic

final class RelayFrameTests: XCTestCase {
    /// A relay sending `[]` trapped the feed's message handler (Tron, 10/15).
    func testAnEmptyOrOddFrameIsSkippedNotACrash() {
        for frame in ["[]", "[1]", "[null]", "[[\"EVENT\"]]", "{}", "\"EVENT\"", "", "[", "not json"] {
            XCTAssertNil(RelayFrame.parse(frame), frame)
        }
    }

    func testAFrameKeepsItsTypeAndArray() {
        let event = RelayFrame.parse(#"[ "EVENT", "feed-x", {"id":"a"} ]"#)
        XCTAssertEqual(event?.type, "EVENT")
        XCTAssertEqual(event?.json.count, 3)
        XCTAssertEqual(event?.json[1] as? String, "feed-x")
        XCTAssertEqual(RelayFrame.parse(#"["EOSE","feed-x"]"#)?.type, "EOSE")
        XCTAssertEqual(RelayFrame.parse(#"["NOTICE"]"#)?.json.count, 1)
    }
}
