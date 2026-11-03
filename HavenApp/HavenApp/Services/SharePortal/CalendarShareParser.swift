import Foundation

/// A shared `.ics` file or a page's JSON-LD Event → a NIP-52 event draft (§6.3).
struct CalendarShareEvent: Equatable {
    enum When: Equatable {
        case date(String)      // YYYY-MM-DD
        case time(Int)         // unix seconds
    }

    var title = ""
    var description = ""
    var location = ""
    var url = ""
    var start: When?
    var end: When?
    var tzid: String?

    var isAllDay: Bool {
        if case .date = start { return true }
        return false
    }
}

enum CalendarShareParser {
    // MARK: ICS

    static func parseICS(_ ics: String, defaultZone: TimeZone) -> CalendarShareEvent {
        let unfolded = ics.replacingOccurrences(of: #"\r?\n[ \t]"#, with: "", options: .regularExpression)
        let lines = unfolded.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var inEvent = false
        var props: [String: (params: [String: String], value: String)] = [:]
        for line in lines {
            let upper = line.trimmingCharacters(in: .whitespaces).uppercased()
            if upper == "BEGIN:VEVENT" { inEvent = true; continue }
            if upper == "END:VEVENT", inEvent { break }
            guard inEvent, let colon = line.firstIndex(of: ":") else { continue }
            let head = line[..<colon]
            let value = String(line[line.index(after: colon)...])
            let parts = head.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
            let name = parts[0].uppercased()
            var params: [String: String] = [:]
            for p in parts.dropFirst() {
                guard let eq = p.firstIndex(of: "=") else { continue }
                params[p[..<eq].uppercased()] = String(p[p.index(after: eq)...]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
            if props[name] == nil { props[name] = (params, value) }
        }
        func text(_ key: String) -> String {
            props[key].map { unescape($0.value).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        }
        var ev = CalendarShareEvent(title: text("SUMMARY"), description: text("DESCRIPTION"),
                                    location: text("LOCATION"),
                                    url: props["URL"]?.value.trimmingCharacters(in: .whitespaces) ?? "")
        if let s = props["DTSTART"], let start = icsTime(s.params, s.value.trimmingCharacters(in: .whitespaces), defaultZone) {
            ev.start = start.when
            ev.tzid = start.tzid
            if let e = props["DTEND"], let end = icsTime(e.params, e.value.trimmingCharacters(in: .whitespaces), defaultZone),
               sameShape(end.when, start.when) {
                ev.end = end.when
            }
            if case .date(let d) = start.when, ev.end == nil { ev.end = nextDay(d).map { .date($0) } }
        }
        return ev
    }

    private static func sameShape(_ a: CalendarShareEvent.When, _ b: CalendarShareEvent.When) -> Bool {
        switch (a, b) {
        case (.date, .date), (.time, .time): return true
        default: return false
        }
    }

    static func unescape(_ v: String) -> String {
        var out = ""
        var it = v.makeIterator()
        while let c = it.next() {
            guard c == "\\" else { out.append(c); continue }
            guard let n = it.next() else { out.append(c); break }
            switch n {
            case "n", "N": out.append("\n")
            case ",", ";", "\\": out.append(n)
            default: out.append("\\"); out.append(n)
            }
        }
        return out
    }

    private static func icsTime(_ params: [String: String], _ value: String, _ defaultZone: TimeZone) -> (when: CalendarShareEvent.When, tzid: String?)? {
        let digits = value.allSatisfy(\.isASCII) && value.count == 8 && value.allSatisfy(\.isNumber)
        if params["VALUE"] == "DATE" || digits {
            guard value.count >= 8 else { return nil }
            let a = Array(value)
            return (.date("\(String(a[0..<4]))-\(String(a[4..<6]))-\(String(a[6..<8]))"), nil)
        }
        let pattern = #"^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})(Z?)$"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
        func g(_ i: Int) -> String { Range(m.range(at: i), in: value).map { String(value[$0]) } ?? "" }
        var zone = defaultZone
        var tzid: String?
        if g(7) == "Z" {
            zone = TimeZone(identifier: "UTC")!
        } else if let id = params["TZID"] {
            guard let tz = TimeZone(identifier: id) else { return nil }
            zone = tz
            tzid = id
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let comps = DateComponents(year: Int(g(1)), month: Int(g(2)), day: Int(g(3)),
                                   hour: Int(g(4)), minute: Int(g(5)), second: Int(g(6)))
        guard let date = cal.date(from: comps) else { return nil }
        return (.time(Int(date.timeIntervalSince1970)), tzid)
    }

    static func nextDay(_ ymd: String) -> String? {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: ymd) else { return nil }
        return f.string(from: d.addingTimeInterval(86_400))
    }

    // MARK: JSON-LD Event

    static func parseEvent(html: String) -> CalendarShareEvent {
        var ev = CalendarShareEvent()
        guard let e = ShareLinkedData.first("Event", in: html) else { return ev }
        ev.title = ShareLinkedData.text(e, "name")
        ev.description = ShareLinkedData.text(e, "description")
        ev.url = (e["url"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        var loc = e["location"]
        if let list = loc as? [Any] { loc = list.first }
        if let s = loc as? String {
            ev.location = ShareLinkedData.clean(s)
        } else if let place = loc as? [String: Any] {
            var bits: [String] = []
            let name = ShareLinkedData.text(place, "name")
            if !name.isEmpty { bits.append(name) }
            if let a = place["address"] as? String {
                let c = ShareLinkedData.clean(a)
                if !c.isEmpty { bits.append(c) }
            } else if let a = place["address"] as? [String: Any] {
                let parts = ["streetAddress", "addressLocality", "addressRegion", "postalCode", "addressCountry"]
                    .map { ShareLinkedData.text(a, $0) }.filter { !$0.isEmpty }
                if !parts.isEmpty { bits.append(parts.joined(separator: ", ")) }
            }
            ev.location = bits.joined(separator: ", ")
        }
        if let s = (e["startDate"] as? String).flatMap(isoTime) {
            ev.start = s
            if let en = (e["endDate"] as? String).flatMap(isoTime), sameShape(en, s) { ev.end = en }
            if case .date(let d) = s, ev.end == nil { ev.end = nextDay(d).map { .date($0) } }
        }
        return ev
    }

    static func isoTime(_ raw: String) -> CalendarShareEvent.When? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil { return .date(s) }
        // An instant needs an offset or Z; a bare local time names no instant.
        guard s.range(of: #"(Z|[+-]\d{2}:?\d{2})$"#, options: .regularExpression) != nil else { return nil }
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]] {
            let f = ISO8601DateFormatter()
            f.formatOptions = options
            if let d = f.date(from: s) { return .time(Int(d.timeIntervalSince1970)) }
        }
        return nil
    }
}

/// NIP-52 tags for a calendar event (§6.3).
enum CalendarShareTags {
    static func kind(for event: CalendarShareEvent) -> Int { event.isAllDay ? 31922 : 31923 }

    static func tags(_ ev: CalendarShareEvent, d: String) -> [[String]] {
        var tags: [[String]] = [["d", d], ["title", ev.title]]
        func value(_ w: CalendarShareEvent.When) -> String {
            switch w {
            case .date(let s): return s
            case .time(let t): return String(t)
            }
        }
        if let start = ev.start { tags.append(["start", value(start)]) }
        if let end = ev.end { tags.append(["end", value(end)]) }
        if !ev.isAllDay, let tz = ev.tzid { tags += [["start_tzid", tz], ["end_tzid", tz]] }
        if !ev.location.isEmpty { tags.append(["location", ev.location]) }
        if !ev.url.isEmpty { tags.append(["r", ev.url]) }
        tags.append(["alt", "Calendar event: \(ev.title)"])
        return tags
    }
}
