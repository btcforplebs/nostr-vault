import SwiftUI

// The Popular feed's own controls: who it ranks (one menu, not two toggles
// that undo each other) and the rank line drawn above each scored post.

extension FeedView {
    func setPopularFilter(_ filter: PopularFilter) {
        feedService.popularFilter = filter
        feedService.recomputeFilteredNotes()
    }

    /// Rank and score for the line above a Popular post, while ranks are shown.
    func popularRank(of note: FeedNote) -> (rank: Int, score: Double)? {
        guard feedService.feedMode == .popular, feedService.showPopularEngagement else { return nil }
        return PopularRankLine.rank(of: note, in: feedService.filteredNotes, scores: feedService.popularNoteScores)
    }
}

extension PopularFilter {
    /// Name in the audience menu and the toolbar note.
    var menuTitle: String {
        switch self {
        case .all: return "Everyone"
        case .follows: return "People you follow"
        case .nonFollows: return "People you don't follow"
        }
    }

    var symbolName: String {
        switch self {
        case .all: return "person.2"
        case .follows: return "person.2.fill"
        case .nonFollows: return "globe.americas.fill"
        }
    }
}

/// Everyone / People you follow / People you don't follow, as one button in
/// the Popular toolbar. Tinted only while it narrows the feed.
struct PopularAudienceMenu: View {
    let selected: PopularFilter
    let color: Color
    let onSelect: (PopularFilter) -> Void

    var body: some View {
        Menu {
            PopularAudienceMenuItems(selected: selected, onSelect: onSelect)
        } label: {
            Image(systemName: selected.symbolName)
                .font(.appSystem(size: 15, weight: .semibold))
                .foregroundColor(selected == .all ? .secondary : color)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .menuIndicator(.hidden)
        #if os(macOS)
        // .borderlessButton flattens the label's modifiers on macOS.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .help("Popular from: \(selected.menuTitle)")
        #endif
        .accessibilityLabel("Popular from")
        .accessibilityValue(selected.menuTitle)
    }
}

/// The audience rows, shared by the toolbar button and the overflow menu.
struct PopularAudienceMenuItems: View {
    let selected: PopularFilter
    let onSelect: (PopularFilter) -> Void

    var body: some View {
        Picker("Popular from", selection: Binding(get: { selected }, set: onSelect)) {
            ForEach(PopularFilter.allCases, id: \.self) { filter in
                Label(filter.menuTitle, systemImage: filter.symbolName).tag(filter)
            }
        }
        .pickerStyle(.inline)
    }
}

/// "🔥 #3 · 1.2k" above a post in the Popular feed. It sits outside the card
/// so it never covers the post's time or menu.
struct PopularRankLine: View {
    let rank: Int
    let score: Double

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "flame.fill")
                .font(.appSystem(size: 11, weight: .semibold))
                .foregroundColor(.orange)
            Text("#\(rank)")
                .font(.appSystem(size: 12, weight: .bold, design: .rounded))
                .foregroundColor(.primary)
            Text("·")
                .font(.appSystem(size: 12))
                .foregroundColor(.secondary)
            Text(Self.formatted(score))
                .font(.appSystem(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)
        }
        .padding(.leading, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Popular rank \(rank), score \(Self.formatted(score))")
        #if os(macOS)
        .help("Rank in this feed · engagement score")
        #endif
    }

    static func formatted(_ score: Double) -> String {
        if score >= 1000 {
            return String(format: "%.1fk", score / 1000)
        }
        return String(format: "%.0f", score)
    }

    /// The post's place among the scored posts now shown, in the feed's own
    /// order (score, then newest). Replies threaded under a post have no score
    /// and take no number, and the audience filter renumbers from #1.
    static func rank(of note: FeedNote, in shown: [FeedNote], scores: [String: Double]) -> (rank: Int, score: Double)? {
        guard let score = scores[note.id] else { return nil }
        let ahead = shown.reduce(0) { count, other in
            guard other.id != note.id, let otherScore = scores[other.id] else { return count }
            let isAhead = otherScore > score || (otherScore == score && other.createdAt > note.createdAt)
            return isAhead ? count + 1 : count
        }
        return (ahead + 1, score)
    }
}
