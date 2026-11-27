import XCTest
@testable import MediaLogic

/// A1/A2: where a Media item's size comes from, and the size sorts' order.
final class MediaItemSizeTests: XCTestCase {
    private let sha = String(repeating: "cd", count: 32)
    private var url: URL { URL(string: "https://blossom.example/\(sha).jpg")! }

    func testFirstPositiveWinsInOrder() {
        XCTAssertEqual(MediaItemSize.first(10, 20), 10, "this device's file before the note")
        XCTAssertEqual(MediaItemSize.first(nil, 20), 20)
        XCTAssertEqual(MediaItemSize.first(0, 20), 20, "0 is unknown, not empty")
        XCTAssertNil(MediaItemSize.first(nil, 0))
    }

    func testKind1063SizeTag() {
        XCTAssertEqual(MediaItemSize.fromTags([["x", sha], ["size", "4096"]], url: url), 4096)
        XCTAssertNil(MediaItemSize.fromTags([["size", "0"]], url: url))
        XCTAssertNil(MediaItemSize.fromTags(nil, url: url))
    }

    func testImetaForThisFileOnly() {
        let other = String(repeating: "ef", count: 32)
        let tags = [["imeta", "url https://blossom.example/\(other).jpg", "size 111"],
                    ["imeta", "url \(url.absoluteString)", "m image/jpeg", "size 2400000"]]
        XCTAssertEqual(MediaItemSize.fromTags(tags, url: url), 2_400_000)
        // Another server's link for the same hash still matches.
        let mirror = URL(string: "https://other.example/\(sha)")!
        XCTAssertEqual(MediaItemSize.fromTags(tags, url: mirror), 2_400_000)
        // Only another file's imeta: no size.
        XCTAssertNil(MediaItemSize.fromTags([tags[0]], url: url))
        XCTAssertEqual(MediaItemSize.fromTags([["imeta", "x \(sha.uppercased())", "size 9"]], url: mirror), 9)
    }

    func testSizeOrderUnknownLastBothWays() {
        XCTAssertEqual(MediaSizeOrder.before(900, 10, largestFirst: true), true)
        XCTAssertEqual(MediaSizeOrder.before(900, 10, largestFirst: false), false)
        XCTAssertEqual(MediaSizeOrder.before(nil, 10, largestFirst: true), false)
        XCTAssertEqual(MediaSizeOrder.before(nil, 10, largestFirst: false), false)
        XCTAssertEqual(MediaSizeOrder.before(10, 0, largestFirst: false), true)
        XCTAssertNil(MediaSizeOrder.before(5, 5, largestFirst: true), "a tie falls back to date")
        XCTAssertNil(MediaSizeOrder.before(nil, 0, largestFirst: true))
    }

    func testRowLine() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 20))!
        let nov3 = cal.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 12))!
        let old = cal.date(from: DateComponents(year: 2024, month: 11, day: 3, hour: 12))!
        let gb = Locale(identifier: "en_GB")
        XCTAssertEqual(MediaSizeOrder.rowLine(size: 2_400_000, type: "Video", date: nov3, now: now, calendar: cal, locale: gb), "2.4 MB · Video · 3 Nov")
        XCTAssertEqual(MediaSizeOrder.rowLine(size: nil, type: "Photo", date: old, now: now, calendar: cal, locale: gb), "— · Photo · 3 Nov 2024")
    }
}
