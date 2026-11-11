import Foundation

/// How a timeline feed draws its rows. One button switches between the two
/// (Logen, 2026-11-11: compact view is gone).
enum FeedLayoutMode: String, Codable, CaseIterable {
    /// Full note cards: media, actions, engagement. Opens with replies off,
    /// so the feed reads as single posts.
    case expanded
    /// Condensed lines grouped into whole conversations, root plus replies.
    /// Opens with replies on.
    case threaded

    /// The layout `raw` names. "condensed" (compact view, removed) and
    /// anything unknown read as expanded.
    init(stored raw: String?) {
        self = raw == FeedLayoutMode.threaded.rawValue ? .threaded : .expanded
    }

    /// An old config may hold "condensed"; decoding must not throw on it.
    init(from decoder: Decoder) throws {
        self.init(stored: try decoder.singleValueContainer().decode(String.self))
    }

    /// The other layout. Feeds that cannot be threaded (grids and card
    /// lists) stay expanded.
    func next(supportsThreading: Bool) -> FeedLayoutMode {
        (self == .expanded && supportsThreading) ? .threaded : .expanded
    }

    /// Threading only makes sense on a timeline of notes; a media grid or an
    /// article list has no replies to gather.
    func clamped(supportsThreading: Bool) -> FeedLayoutMode {
        supportsThreading ? self : .expanded
    }

    /// True when rows draw as condensed lines: threaded keeps that look.
    var usesCondensedRows: Bool {
        self == .threaded
    }

    /// What Show replies becomes when the reader switches to this layout.
    /// They can still flip it by hand afterwards in either layout.
    var showsRepliesOnSwitch: Bool {
        self == .threaded
    }

    var symbolName: String {
        switch self {
        case .expanded:  return "rectangle.expand.vertical"
        case .threaded:  return "list.bullet.indent"
        }
    }

    /// Names the layout that is currently on, for tooltips and menu labels.
    var displayName: String {
        switch self {
        case .expanded:  return "Expanded View"
        case .threaded:  return "Threaded View"
        }
    }

    /// What tapping the control will switch to, so the button can say where it
    /// goes rather than only where it is.
    func nextDisplayName(supportsThreading: Bool) -> String {
        next(supportsThreading: supportsThreading).displayName
    }

    /// Rewrites a saved config's compact choices as expanded. A feed saved
    /// as "condensed", or one with no layout saved and the legacy per-feed
    /// compact switch on, becomes "expanded". `hadCompact` says whether any
    /// did, so the caller turns replies off once, as switching to expanded
    /// does.
    static func migrateCompact(
        layouts: [String: String],
        legacyCompact: [String: Bool]
    ) -> (layouts: [String: String], hadCompact: Bool) {
        var out = layouts
        var hadCompact = false
        for (feed, raw) in layouts where raw == "condensed" {
            out[feed] = expanded.rawValue
            hadCompact = true
        }
        for (feed, compact) in legacyCompact where compact && layouts[feed] == nil {
            out[feed] = expanded.rawValue
            hadCompact = true
        }
        return (out, hadCompact)
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

/// Text for a threaded line, which shows only a few lines.
enum CondensedText {
    /// Drops blank lines (and lines left empty once URLs are stripped) and
    /// trims the ends. A post with blank lines between paragraphs spent the
    /// line limit on them, so the preview came out as one line and "...".
    static func squeezeBlankLines(_ text: String) -> String {
        text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// The text on one line: every run of spaces and line breaks becomes one
    /// space. For the parent quote over a reply in the thread view, which
    /// shows a single line and would otherwise stop at the first break.
    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }
}
