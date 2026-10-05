import Foundation

/// How a timeline feed draws its rows. One control cycles through these in
/// order, so the three layouts are one setting rather than three toggles.
enum FeedLayoutMode: String, Codable, CaseIterable {
    /// Full note cards: media, actions, engagement.
    case expanded
    /// One note per line: avatar, name, three lines of text, a media thumbnail.
    case condensed
    /// Condensed lines grouped into whole conversations, root plus replies.
    case threaded

    /// The next layout in the cycle. Feeds that cannot be threaded (grids and
    /// card lists) skip straight back to expanded.
    func next(supportsThreading: Bool) -> FeedLayoutMode {
        switch self {
        case .expanded:
            return .condensed
        case .condensed:
            return supportsThreading ? .threaded : .expanded
        case .threaded:
            return .expanded
        }
    }

    /// Threading only makes sense on a timeline of notes; a media grid or an
    /// article list has no replies to gather.
    func clamped(supportsThreading: Bool) -> FeedLayoutMode {
        (self == .threaded && !supportsThreading) ? .condensed : self
    }

    /// True when rows draw as condensed lines — both condensed layouts do.
    var usesCondensedRows: Bool {
        self != .expanded
    }

    var symbolName: String {
        switch self {
        case .expanded:  return "rectangle.expand.vertical"
        case .condensed: return "rectangle.compress.vertical"
        case .threaded:  return "list.bullet.indent"
        }
    }

    /// Names the layout that is currently on, for tooltips and menu labels.
    var displayName: String {
        switch self {
        case .expanded:  return "Expanded View"
        case .condensed: return "Compact View"
        case .threaded:  return "Threaded View"
        }
    }

    /// What tapping the control will switch to, so the button can say where it
    /// goes rather than only where it is.
    func nextDisplayName(supportsThreading: Bool) -> String {
        next(supportsThreading: supportsThreading).displayName
    }

    /// Resolve the stored layout for a feed, falling back to the per-feed
    /// compact-mode boolean that shipped before this setting existed. Without
    /// this, everyone who had chosen compact mode would silently be reset to
    /// expanded on upgrade.
    ///
    /// - Parameters:
    ///   - storedLayout: `feedLayoutModes[feed]`, once the user has cycled.
    ///   - storedCompact: the legacy `feedCompactModes[feed]` override.
    ///   - defaultCompact: this feed's built-in compact default.
    static func resolve(
        storedLayout: String?,
        storedCompact: Bool?,
        defaultCompact: Bool
    ) -> FeedLayoutMode {
        if let storedLayout, let mode = FeedLayoutMode(rawValue: storedLayout) {
            return mode
        }
        return (storedCompact ?? defaultCompact) ? .condensed : .expanded
    }
}

/// Which feeds the feed picker lists, and in what order. The reader edits
/// both; stored as raw values so a feed added in a later version still
/// appears (at its default place) and one that was removed is dropped.
enum FeedMenuOrder {
    /// The feeds to list, in the reader's order. `pinned` (the home feed)
    /// can't be hidden. New feeds the stored order doesn't know about go in
    /// after the feed that precedes them by default.
    static func ordered(stored: [String], defaults: [String]) -> [String] {
        var out = stored.filter { defaults.contains($0) }
        var seen = Set<String>()
        out = out.filter { seen.insert($0).inserted }
        for (index, value) in defaults.enumerated() where !seen.contains(value) {
            let before = defaults[..<index].last { out.contains($0) }
            let at = before.flatMap { out.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
            out.insert(value, at: at)
            seen.insert(value)
        }
        return out
    }

    static func visible(stored: [String], hidden: [String], defaults: [String], pinned: String) -> [String] {
        let hiddenSet = Set(hidden).subtracting([pinned])
        return ordered(stored: stored, defaults: defaults).filter { !hiddenSet.contains($0) }
    }

    /// Stored as one comma-separated string so `@AppStorage` can hold it.
    static func decode(_ string: String) -> [String] {
        string.split(separator: ",").map(String.init).filter { !$0.isEmpty }
    }

    static func encode(_ values: [String]) -> String {
        values.joined(separator: ",")
    }
}
