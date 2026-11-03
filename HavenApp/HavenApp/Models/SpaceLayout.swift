import Foundation

/// The iPad's desktop layout, shared with the web vault: the left rail's pins
/// (sections and favourites, in order) and Your space's panels. The format and
/// every rule here are in docs/SPACE_LAYOUT.md; the web's twin is
/// `web-vault/src/desktop/space/space-layout.js`. Pure, so MediaLogicTests
/// covers it.
///
/// Entries this app does not understand (a pin type, section or panel from a
/// newer app) and top-level keys it does not use are kept exactly as read, so
/// a round trip through this app never loses them.
struct SpaceLayout: Equatable {
    static let version = 1
    /// The NIP-78 `d` of the synced event.
    static let syncD = "nostr-vault-space-layout"
    static let maxFavourites = 30

    /// Every section id the format names, in the default order.
    static let allSections = ["feed", "search", "profile", "wot", "vault", "messages", "notifications", "relay", "settings"]

    var at: Int64
    var pins: [Pin]
    var panels: [Panel]
    /// Top-level keys other than v, at, pins, panels.
    var extra: [String: JSONValue] = [:]

    // MARK: Pins

    struct Pin: Equatable, Identifiable {
        enum Kind: Equatable {
            case section(String)
            case list(String)
            case person(String)
            case hashtag(String)
            case relay(String)
            case unknown
        }

        /// The entry as stored, with its value normalised.
        var raw: [String: JSONValue]

        var kind: Kind {
            let value = { (key: String) in raw[key]?.string ?? "" }
            switch raw["type"]?.string {
            case "section": return .section(value("id"))
            case "list": return .list(value("a"))
            case "person": return .person(value("p"))
            case "hashtag": return .hashtag(value("t"))
            case "relay": return .relay(value("url"))
            default: return .unknown
            }
        }

        /// type + value: two pins with the same one are the same pin.
        var id: String {
            let type = raw["type"]?.string ?? "?"
            let field = Self.valueField[type] ?? ""
            return "\(type):\(raw[field]?.string ?? JSONValue.object(raw).canonical)"
        }

        var name: String? { raw["name"]?.string }
        var isSection: Bool { if case .section = kind { return true } else { return false } }

        static let valueField = ["section": "id", "list": "a", "person": "p", "hashtag": "t", "relay": "url"]

        static func section(_ id: String) -> Pin { Pin(raw: ["type": .string("section"), "id": .string(id)]) }

        /// A favourite, or nil when the value is not a valid one.
        static func favourite(_ kind: Kind, name: String? = nil) -> Pin? {
            let entry: (String, String, String)
            switch kind {
            case .list(let a): entry = ("list", "a", a)
            case .person(let p): entry = ("person", "p", p)
            case .hashtag(let t): entry = ("hashtag", "t", t)
            case .relay(let url): entry = ("relay", "url", url)
            case .section, .unknown: return nil
            }
            guard let value = SpaceLayout.normalisedValue(type: entry.0, entry.2) else { return nil }
            var raw: [String: JSONValue] = ["type": .string(entry.0), entry.1: .string(value)]
            if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty { raw["name"] = .string(name) }
            return Pin(raw: raw)
        }
    }

    // MARK: Panels

    struct Panel: Equatable, Identifiable {
        var raw: [String: JSONValue]
        var id: String { raw["id"]?.string ?? "" }
        var on: Bool {
            get { raw["on"]?.bool ?? true }
            set { raw["on"] = .bool(newValue) }
        }
        var open: Bool {
            get { raw["open"]?.bool ?? true }
            set { raw["open"] = .bool(newValue) }
        }
        static func make(_ id: String, on: Bool = true, open: Bool = true) -> Panel {
            Panel(raw: ["id": .string(id), "on": .bool(on), "open": .bool(open)])
        }
    }

    // MARK: Defaults

    static func defaultLayout(panelIds: [String], at: Int64 = 0) -> SpaceLayout {
        SpaceLayout(at: at, pins: allSections.map(Pin.section), panels: panelIds.map { Panel.make($0) })
    }

    // MARK: Normalise

    /// Normalises a pin value, or nil when it is not a valid one (doc table).
    static func normalisedValue(type: String, _ value: String) -> String? {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return nil }
        switch type {
        case "section":
            return v
        case "person":
            let hex = v.lowercased()
            return isHex64(hex) ? hex : nil
        case "hashtag":
            let tag = String(v.drop(while: { $0 == "#" })).lowercased()
            return tag.isEmpty || tag.contains(where: \.isWhitespace) ? nil : tag
        case "list":
            let parts = v.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3, parts[0] == "30000" || parts[0] == "39089" else { return nil }
            let pk = parts[1].lowercased()
            guard isHex64(pk), !parts[2].isEmpty else { return nil }
            return "\(parts[0]):\(pk):\(parts[2])"
        case "relay":
            return normaliseRelay(v)
        default:
            return v
        }
    }

    static func normaliseRelay(_ url: String) -> String? {
        guard var parts = URLComponents(string: url.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = parts.scheme?.lowercased(), scheme == "wss" || scheme == "ws",
              let host = parts.host, !host.isEmpty else { return nil }
        parts.scheme = scheme
        parts.host = host.lowercased()
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        return parts.string
    }

    private static func isHex64(_ s: String) -> Bool {
        s.count == 64 && s.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// How far ahead of this device's clock `at` may be. Further ahead, it is
    /// pulled back to now plus this, so a device whose clock runs fast can't
    /// win every later comparison. Same window as `ListMerge.maxSkew`.
    static let maxSkew: Int64 = 15 * 60

    /// Any saved value -> a clean layout against the sections and panels this
    /// app has (docs/SPACE_LAYOUT.md, "Normalising"). Returns nil for a
    /// layout from a newer format (`v` above ours): leave that one alone.
    /// Numbers are checked before they are converted: a huge one (1e300)
    /// traps a Double-to-Int conversion, and this runs on every launch.
    static func normalize(_ value: JSONValue?, sections: [String], panelIds: [String],
                          now: Int64 = Int64(Date().timeIntervalSince1970)) -> SpaceLayout? {
        // `v` is a whole number; anything else is not a layout.
        guard case .object(let top)? = value, let v = top["v"]?.number,
              v.isFinite, v >= 0, v == v.rounded() else {
            return defaultLayout(panelIds: panelIds)
        }
        if v > Double(version) { return nil }

        var pins: [Pin] = []
        var seen = Set<String>()
        var favourites = 0
        if case .array(let entries)? = top["pins"] {
            for entry in entries {
                guard case .object(var raw) = entry, let type = raw["type"]?.string else { continue }
                if let field = Pin.valueField[type] {
                    guard let value = raw[field]?.string, let clean = normalisedValue(type: type, value) else { continue }
                    raw[field] = .string(clean)
                }
                let pin = Pin(raw: raw)
                guard seen.insert(pin.id).inserted else { continue }
                if !pin.isSection, pin.kind != .unknown {
                    guard favourites < maxFavourites else { continue }
                    favourites += 1
                }
                pins.append(pin)
            }
        }
        // Sections never go: a known one left out goes back at its default place.
        for (i, id) in sections.enumerated() where !pins.contains(where: { $0.kind == .section(id) }) {
            let before = sections[..<i].reversed().first { b in pins.contains { $0.kind == .section(b) } }
            let at = before.flatMap { b in pins.firstIndex { $0.kind == .section(b) } }.map { $0 + 1 } ?? 0
            pins.insert(.section(id), at: at)
        }

        var panels: [Panel] = []
        var seenPanels = Set<String>()
        if case .array(let entries)? = top["panels"] {
            for entry in entries {
                guard case .object(let raw) = entry, let id = raw["id"]?.string, !id.isEmpty,
                      seenPanels.insert(id).inserted else { continue }
                var panel = Panel(raw: raw)
                panel.on = raw["on"]?.bool ?? true
                panel.open = raw["open"]?.bool ?? true
                panels.append(panel)
            }
        }
        for (i, id) in panelIds.enumerated() where !seenPanels.contains(id) {
            seenPanels.insert(id)
            let before = panelIds[..<i].reversed().first { b in panels.contains { $0.id == b } }
            let at = before.flatMap { b in panels.firstIndex { $0.id == b } }.map { $0 + 1 } ?? 0
            panels.insert(.make(id), at: at)
        }

        var extra = top
        for key in ["v", "at", "pins", "panels"] { extra[key] = nil }
        let at = clampedAt(top["at"]?.number, now: now)
        return SpaceLayout(at: at, pins: pins, panels: panels, extra: extra)
    }

    /// `at` as whole seconds from 0 to `now + maxSkew`; 0 when missing or not a number.
    static func clampedAt(_ value: Double?, now: Int64) -> Int64 {
        guard let value, value.isFinite, value > 0 else { return 0 }
        let ceiling = now + maxSkew
        return value >= Double(ceiling) ? ceiling : Int64(value)
    }

    static func decode(_ data: Data?, sections: [String], panelIds: [String],
                       now: Int64 = Int64(Date().timeIntervalSince1970)) -> SpaceLayout? {
        let value = data.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
        return normalize(value, sections: sections, panelIds: panelIds, now: now)
    }

    var json: JSONValue {
        var top = extra
        top["v"] = .number(Double(Self.version))
        top["at"] = .number(Double(at))
        top["pins"] = .array(pins.map { .object($0.raw) })
        top["panels"] = .array(panels.map { .object($0.raw) })
        return .object(top)
    }

    func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(json)) ?? Data()
    }

    // MARK: Sync read

    /// What a read of the synced event decides.
    struct SyncDecision: Equatable {
        /// The layout to draw (and keep on the device).
        var layout: SpaceLayout
        /// This device has now seen the synced layout (opened it, or every
        /// relay confirmed none), so its edits may be published.
        var baseKnown: Bool
        /// Publish the device's copy now: it is newer than what is synced.
        var publish: Bool
        /// The synced layout is from a newer format: never write over it.
        var newerFormat = false
    }

    /// `plaintext`: the decrypted event content, nil when there was no event
    /// or it couldn't be opened. `confirmedNone`: every relay asked answered
    /// and none had one. Anything short of an opened event or a confirmed
    /// none leaves the base unknown, so edits stay on the device.
    static func syncRead(local: SpaceLayout, plaintext: String?, confirmedNone: Bool,
                         sections: [String], panelIds: [String],
                         now: Int64 = Int64(Date().timeIntervalSince1970)) -> SyncDecision {
        guard let plaintext else {
            return SyncDecision(layout: local, baseKnown: confirmedNone, publish: confirmedNone && local.at > 0)
        }
        guard let remote = decode(Data(plaintext.utf8), sections: sections, panelIds: panelIds, now: now) else {
            return SyncDecision(layout: local, baseKnown: false, publish: false, newerFormat: true)
        }
        if remoteWins(remote: remote, local: local) {
            return SyncDecision(layout: remote, baseKnown: true, publish: false)
        }
        return SyncDecision(layout: local, baseKnown: true, publish: local.at > remote.at)
    }

    // MARK: Which wins

    /// The downloaded layout replaces the device's only when it is newer.
    static func remoteWins(remote: SpaceLayout, local: SpaceLayout) -> Bool { remote.at > local.at }

    // MARK: Edits (each sets `at`)

    /// The panels to draw, in order: shown and known.
    func shownPanels(_ ids: [String]) -> [Panel] { panels.filter { $0.on && ids.contains($0.id) } }
    /// Known panels taken off, in the default order.
    func hiddenPanels(_ ids: [String]) -> [String] { ids.filter { id in panels.contains { $0.id == id && !$0.on } } }

    func settingPanel(_ id: String, on: Bool? = nil, open: Bool? = nil, at: Int64) -> SpaceLayout {
        var next = self
        next.panels = panels.map { p in
            guard p.id == id else { return p }
            var q = p
            if let on { q.on = on }
            if let open { q.open = open }
            return q
        }
        next.at = at
        return next
    }

    /// Moves a shown panel one place up (-1) or down (+1) among the drawn
    /// ones; hidden and unknown panels keep their places in between.
    func movingPanel(_ id: String, by delta: Int, ids: [String], at: Int64) -> SpaceLayout {
        let drawn = shownPanels(ids).map(\.id)
        guard let i = drawn.firstIndex(of: id), drawn.indices.contains(i + delta) else { return self }
        let other = drawn[i + delta]
        guard let a = panels.firstIndex(where: { $0.id == id }),
              let b = panels.firstIndex(where: { $0.id == other }) else { return self }
        var next = self
        next.panels.swapAt(a, b)
        next.at = at
        return next
    }

    /// The pins the rail draws, in order: sections it has and known favourites.
    func shownPins(sections: [String]) -> [Pin] {
        pins.filter { pin in
            switch pin.kind {
            case .section(let id): return sections.contains(id)
            case .unknown: return false
            default: return true
            }
        }
    }

    var favouriteCount: Int { pins.filter { !$0.isSection && $0.kind != .unknown }.count }

    /// Adds a favourite at the end of the drawn pins, or nil when it is
    /// already there or the rail is full.
    func addingPin(_ pin: Pin, at: Int64) -> SpaceLayout? {
        guard !pin.isSection, pin.kind != .unknown, !pins.contains(where: { $0.id == pin.id }),
              favouriteCount < Self.maxFavourites else { return nil }
        var next = self
        next.pins.append(pin)
        next.at = at
        return next
    }

    /// Removes a favourite. Sections never go.
    func removingPin(_ id: String, at: Int64) -> SpaceLayout {
        guard let i = pins.firstIndex(where: { $0.id == id }), !pins[i].isSection else { return self }
        var next = self
        next.pins.remove(at: i)
        next.at = at
        return next
    }

    /// Moves drawn pins (`List.onMove` offsets over `shownPins`), keeping the
    /// pins this app doesn't draw where they are relative to the others.
    func movingPins(from source: IndexSet, to destination: Int, sections: [String], at: Int64) -> SpaceLayout {
        var drawn = shownPins(sections: sections)
        guard !drawn.isEmpty else { return self }
        let moving = source.sorted().compactMap { drawn.indices.contains($0) ? drawn[$0] : nil }
        let below = source.filter { $0 < destination }.count
        drawn.removeAll { pin in moving.contains { $0.id == pin.id } }
        drawn.insert(contentsOf: moving, at: max(0, min(destination - below, drawn.count)))
        // Put the drawn pins back into the slots drawn pins held.
        var queue = drawn[...]
        var next = self
        next.pins = pins.map { pin in
            let isDrawn = shownPins(sections: sections).contains { $0.id == pin.id }
            return isDrawn ? (queue.popFirst() ?? pin) : pin
        }
        next.at = at
        return next
    }

    func resettingPanels(panelIds: [String], at: Int64) -> SpaceLayout {
        var next = self
        let unknown = panels.filter { !panelIds.contains($0.id) }
        next.panels = panelIds.map { Panel.make($0) } + unknown
        next.at = at
        return next
    }
}

// MARK: - JSON value

/// A JSON value kept as read, so unknown entries survive a round trip.
enum JSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n):
            if n.rounded() == n, abs(n) < 1e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    var string: String? { if case .string(let s) = self { return s } else { return nil } }
    var bool: Bool? { if case .bool(let b) = self { return b } else { return nil } }
    var number: Double? { if case .number(let n) = self { return n } else { return nil } }

    /// Sorted-key JSON text, for telling unknown entries apart.
    var canonical: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}
