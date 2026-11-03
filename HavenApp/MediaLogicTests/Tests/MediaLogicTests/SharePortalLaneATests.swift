import XCTest
@testable import MediaLogic

/// Lane A of the Share Portal (contract §6): article clip, recipe, calendar,
/// status, label. Same fixture file as Android's lane A tests.
final class SharePortalLaneATests: XCTestCase {
    private var fx: [String: Any] = [:]

    override func setUpWithError() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "lane-a-cases", withExtension: "json", subdirectory: "Fixtures/SharePortal"))
        fx = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func cases(_ key: String) throws -> [[String: Any]] {
        let list = try XCTUnwrap(fx[key] as? [[String: Any]], key)
        XCTAssertFalse(list.isEmpty, key)
        return list
    }

    private func str(_ v: Any?) -> String? { v as? String }

    func testArticleClip() throws {
        for c in try cases("clip") {
            let name = c["name"] as? String ?? "?"
            let i = c["input"] as? [String: Any] ?? [:]
            let e = c["expect"] as? [String: String] ?? [:]
            let title = ArticleClipDraft.title(str(i["title"]), url: str(i["url"]))
            XCTAssertEqual(title, e["title"], name)
            XCTAssertEqual(ArticleClipDraft.body(title: title, url: str(i["url"]), selection: str(i["selection"])), e["body"], name)
        }
    }

    func testDurations() throws {
        for c in try cases("duration") {
            XCTAssertEqual(RecipeLdParser.duration(c["in"] as? String ?? ""), c["out"] as? String, c["in"] as? String ?? "")
        }
    }

    func testRecipe() throws {
        for c in try cases("recipe") {
            let name = c["name"] as? String ?? "?"
            let f = RecipeLdParser.parse(html: c["html"] as? String ?? "", pageTitle: str(c["page_title"]), url: str(c["url"]))
            let e = c["expect"] as? [String: String] ?? [:]
            XCTAssertEqual(f, RecipeLdParser.Fields(title: e["title"] ?? "", summary: e["summary"] ?? "", prepTime: e["prepTime"] ?? "",
                                                    cookTime: e["cookTime"] ?? "", servings: e["servings"] ?? "",
                                                    ingredients: e["ingredients"] ?? "", directions: e["directions"] ?? "",
                                                    categories: e["categories"] ?? "", body: e["body"] ?? ""), name)
        }
    }

    static func event(_ e: [String: Any]) -> CalendarShareEvent {
        let allDay = e["all_day"] as? Bool ?? false
        func when(_ v: Any?) -> CalendarShareEvent.When? {
            if let s = v as? String { return .date(s) }
            if let n = v as? Int { return .time(n) }
            return nil
        }
        _ = allDay
        return CalendarShareEvent(title: e["title"] as? String ?? "", description: e["description"] as? String ?? "",
                                  location: e["location"] as? String ?? "", url: e["url"] as? String ?? "",
                                  start: when(e["start"]), end: when(e["end"]), tzid: e["tzid"] as? String)
    }

    func testICS() throws {
        for c in try cases("ics") {
            let name = c["name"] as? String ?? "?"
            let zone = try XCTUnwrap(TimeZone(identifier: c["default_tz"] as? String ?? ""))
            let e = c["expect"] as? [String: Any] ?? [:]
            let got = CalendarShareParser.parseICS(c["ics"] as? String ?? "", defaultZone: zone)
            XCTAssertEqual(got, Self.event(e), name)
            XCTAssertEqual(got.isAllDay, e["all_day"] as? Bool, name)
        }
    }

    func testEventLD() throws {
        for c in try cases("event_ld") {
            let name = c["name"] as? String ?? "?"
            let e = c["expect"] as? [String: Any] ?? [:]
            XCTAssertEqual(CalendarShareParser.parseEvent(html: c["html"] as? String ?? ""), Self.event(e), name)
        }
    }

    func testCalendarTags() throws {
        for c in try cases("calendar_tags") {
            let name = c["name"] as? String ?? "?"
            let ev = Self.event(c["event"] as? [String: Any] ?? [:])
            let e = c["expect"] as? [String: Any] ?? [:]
            XCTAssertEqual(CalendarShareTags.kind(for: ev), e["kind"] as? Int, name)
            XCTAssertEqual(CalendarShareTags.tags(ev, d: c["d"] as? String ?? ""), e["tags"] as? [[String]], name)
            XCTAssertEqual(ev.description, e["content"] as? String, name)
        }
    }

    func testStatusTags() throws {
        for c in try cases("status_tags") {
            let e = c["expect"] as? [String: Any] ?? [:]
            let text = c["text"] as? String ?? ""
            XCTAssertEqual(StatusShareTags.tags(text: text, url: str(c["url"]), expiration: c["expiration"] as? Int ?? 0),
                           e["tags"] as? [[String]])
            XCTAssertEqual(text.trimmingCharacters(in: .whitespacesAndNewlines), e["content"] as? String)
            XCTAssertEqual(StatusShareTags.kind, e["kind"] as? Int)
        }
    }

    func testLabelTags() throws {
        XCTAssertEqual(LabelShareTags.labels, fx["labels"] as? [String])
        XCTAssertEqual(LabelShareTags.namespace, fx["label_namespace"] as? String)
        for c in try cases("label_tags") {
            let e = c["expect"] as? [String: Any] ?? [:]
            XCTAssertEqual(LabelShareTags.tags(label: c["label"] as? String ?? "", url: c["url"] as? String ?? ""), e["tags"] as? [[String]])
            XCTAssertEqual(LabelShareTags.kind, e["kind"] as? Int)
        }
        XCTAssertNil(LabelShareTags.tags(label: "illegal", url: "https://x"))
    }

    func testLaneAActionsAreOffered() {
        let offered = Set(NVShareActionAvailability.offered(NVShareAction.allCases))
        XCTAssertTrue([.articleClip, .recipe, .calendar, .status, .label].allSatisfy { offered.contains($0) })
    }
}
