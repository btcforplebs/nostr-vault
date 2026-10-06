import SwiftUI

/// The Polls feed: NIP-88 polls only, through the main note pipeline the way
/// Articles is (FeedService `.polls`), so Following / Global, the shield,
/// auto-load, the "N new" pill, paging and pull to refresh all work as they
/// do on the timeline. This file holds the parts only Polls has.
@MainActor
enum PollsFeed {
    /// Following / Global. Global starts on the Web of Trust; only the
    /// shield's Everyone warns.
    static func setScope(_ mode: MediaFeedMode, feedService: FeedService = .shared) {
        guard feedService.pollsFeedMode != mode else { return }
        feedService.pollsFeedMode = mode
        feedService.refresh()
    }

    /// Open / Closed / All only re-filters: every poll is already loaded.
    static func setStatus(_ filter: PollStatusFilter, feedService: FeedService = .shared) {
        guard feedService.pollStatusFilter != filter else { return }
        feedService.pollStatusFilter = filter
        feedService.recomputeFilteredNotes()
    }
}

extension PollStatusFilter {
    var symbolName: String {
        switch self {
        case .all: return "list.bullet"
        case .open: return "circle"
        case .closed: return "checkmark.circle"
        }
    }
}

/// The Open / Closed / All button in the feed's toolbar.
struct PollStatusFilterMenu: View {
    let selected: PollStatusFilter
    let color: Color

    var body: some View {
        Menu {
            PollStatusFilterMenuItems(selected: selected)
        } label: {
            Image(systemName: selected == .all
                  ? "line.3.horizontal.decrease.circle"
                  : "line.3.horizontal.decrease.circle.fill")
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
        .help("Polls: \(selected.rawValue)")
        #endif
        .accessibilityLabel("Poll status")
        .accessibilityValue(selected.rawValue)
    }
}

/// The filter's rows, shared by the toolbar button and the overflow menu.
struct PollStatusFilterMenuItems: View {
    let selected: PollStatusFilter

    var body: some View {
        ForEach(PollStatusFilter.allCases, id: \.self) { filter in
            Button { PollsFeed.setStatus(filter) } label: {
                Label(filter.rawValue, systemImage: selected == filter ? "checkmark" : filter.symbolName)
            }
        }
    }
}

/// Shown when the Polls feed has nothing to list.
struct PollsEmptyStateView: View {
    let scope: MediaFeedMode
    let status: PollStatusFilter
    var onPost: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: FeedMode.polls.symbolName)
                .font(.appSystem(size: 34))
                .foregroundColor(.havenPurple.opacity(0.7))
            Text(title)
                .font(.appSystem(size: 16, weight: .bold))
            Text(scope == .following
                 ? "Polls from people you follow show up here."
                 : "Polls from across Nostr show up here.")
                .font(.appSystem(size: 13))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            if let onPost {
                Button("Post a poll", action: onPost)
                    .font(.appSystem(size: 14, weight: .semibold))
                    .foregroundColor(.havenPurple)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 60)
        .frame(maxWidth: .infinity)
    }

    private var title: String {
        switch status {
        case .all: return "No polls yet"
        case .open: return "No open polls"
        case .closed: return "No closed polls"
        }
    }
}

/// What a condensed Polls row adds after the question: the vote count and
/// how long is left. Reads the shared `PollStore` model, so the count is the
/// one the full card shows.
struct PollCondensedStatus: View {
    let poll: NIP88Poll.Poll
    @StateObject private var model: PollModel

    init(poll: NIP88Poll.Poll) {
        self.poll = poll
        _model = StateObject(wrappedValue: PollStore.shared.model(for: poll))
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(model.tally.voters.count == 1 ? "1 vote" : "\(model.tally.voters.count) votes")
            if let endsAt = poll.endsAt {
                if poll.isClosed() {
                    Text("· Closed")
                } else {
                    Text("· Ends ") + Text(endsAt, format: .relative(presentation: .named))
                }
            }
        }
        .font(.appSystem(size: 12, weight: .medium))
        .foregroundColor(.secondary)
        .lineLimit(1)
        .task { await model.load() }
    }
}
