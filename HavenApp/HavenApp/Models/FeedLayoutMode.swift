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
