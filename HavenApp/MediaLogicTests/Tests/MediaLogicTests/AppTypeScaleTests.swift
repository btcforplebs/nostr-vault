import XCTest
@testable import MediaLogic

final class AppTypeScaleTests: XCTestCase {
    func testMacUsesMacSizes() {
        XCTAssertEqual(AppTypeScale.size(.body, mac: true), 13)
        XCTAssertEqual(AppTypeScale.size(.headline, mac: true), 13)
        XCTAssertEqual(AppTypeScale.size(.title2, mac: true), 17)
    }

    func testPhoneKeepsIOSSizes() {
        XCTAssertEqual(AppTypeScale.size(.body, mac: false), 17)
        XCTAssertEqual(AppTypeScale.size(.headline, mac: false), 17)
        XCTAssertEqual(AppTypeScale.size(.title2, mac: false), 22)
        XCTAssertEqual(AppTypeScale.size(.caption2, mac: false), 11)
    }

    func testMacStylesKeepTheirOrderAndFloor() {
        let order: [AppTypeScale.Style] = [.largeTitle, .title, .title2, .title3, .headline, .body,
                                           .callout, .subheadline, .footnote, .caption, .caption2]
        XCTAssertEqual(Set(order).count, AppTypeScale.Style.allCases.count)
        for mac in [true, false] {
            let sizes = order.map { AppTypeScale.size($0, mac: mac) }
            XCTAssertEqual(sizes, sizes.sorted(by: >), "styles out of order, mac=\(mac)")
        }
        for style in AppTypeScale.Style.allCases {
            XCTAssertGreaterThanOrEqual(AppTypeScale.size(style, mac: true), AppTypeScale.macMinimum)
            XCTAssertLessThanOrEqual(AppTypeScale.size(style, mac: true), AppTypeScale.size(style, mac: false))
        }
    }

    func testFloorOnlyOnMac() {
        XCTAssertEqual(AppTypeScale.floored(8, mac: true), 10)
        XCTAssertEqual(AppTypeScale.floored(13, mac: true), 13)
        XCTAssertEqual(AppTypeScale.floored(8, mac: false), 8)
    }
}
