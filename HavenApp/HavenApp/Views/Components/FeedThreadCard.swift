import SwiftUI

/// One conversation in the feed: a root note plus its replies, drawn as a
/// single card of condensed lines rather than one card per note.
///
/// Replies past `collapsedReplyLimit` stay folded so a long argument can't take
/// over the timeline; the fold opens in place instead of pushing a new screen.
struct FeedThreadCard: View {
    let thread: FeedThread<FeedNote>
    let profileFor: (String) -> FeedProfile?
    var focusedNoteId: String? = nil
    /// Opens the thread at a given note. nil makes the lines non-interactive,
    /// which the enclosing navigation link relies on.
    var onSelect: ((FeedNote) -> Void)? = nil
    var onProfile: ((String) -> Void)? = nil

    @State private var isExpanded = false
    @Environment(\.feedActions) private var actions

    /// Three replies is enough to show a conversation is happening without
    /// letting one thread own the screen.
    private static let collapsedReplyLimit = 3

    private var replies: [FeedThreadEntry<FeedNote>] { thread.replies }

    private var visibleReplies: [FeedThreadEntry<FeedNote>] {
        guard !isExpanded, replies.count > Self.collapsedReplyLimit else { return replies }
        return Array(replies.prefix(Self.collapsedReplyLimit))
    }

    private var hiddenReplyCount: Int { replies.count - visibleReplies.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let root = thread.root {
                line(for: FeedThreadEntry(note: root, depth: 0), replyCount: directReplyCount(of: root.id))
            } else {
                missingRootHeader
            }

            ForEach(visibleReplies) { entry in
                line(for: entry, replyCount: directReplyCount(of: entry.note.id))
            }

            if hiddenReplyCount > 0 {
                expandButton
            } else if isExpanded && replies.count > Self.collapsedReplyLimit {
                collapseButton
            }
        }
        .threadCard()
        .animation(Motion.panel, value: isExpanded)
        .onAppear {
            // The feed can hold replies whose root it never loaded. Fetch it so
            // the conversation gets its opening line.
            if thread.root == nil {
                actions.fetchMissingNote(thread.rootId)
            }
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func line(for entry: FeedThreadEntry<FeedNote>, replyCount: Int) -> some View {
        let note = entry.note
        CondensedNoteLine(
            note: note,
            profile: profileFor(note.pubkey),
            depth: entry.depth,
            style: .plain,
            isFocused: note.id == focusedNoteId,
            replyCount: replyCount,
            contentOverride: note.kind == 30023 ? note.longFormDisplayTitle : nil,
            mediaURLs: note.mediaURLs,
            onProfile: onProfile,
            onTap: onSelect.map { select in { select(note) } }
        )
    }

    /// Stands in for a root the relay hasn't returned yet, so replies aren't
    /// left dangling with no opening line.
    private var missingRootHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.appSystem(size: 12, weight: .semibold))
                .foregroundColor(Color.havenPurple.opacity(0.7))
            Text("Loading the start of this thread…")
                .font(.appSystem(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var expandButton: some View {
        threadButton(
            icon: "arrow.turn.down.right",
            title: "Show \(hiddenReplyCount) more \(hiddenReplyCount == 1 ? "reply" : "replies")"
        ) {
            isExpanded = true
        }
    }

    private var collapseButton: some View {
        threadButton(icon: "chevron.up", title: "Show fewer replies") {
            isExpanded = false
        }
    }

    private func threadButton(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.appSystem(size: 11, weight: .bold))
                Text(title)
                    .font(.appSystem(size: 12, weight: .bold, design: .rounded))
            }
            .foregroundColor(Color.havenPurple)
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(Color.havenPurple.opacity(0.1))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .padding(.leading, 22)
        .padding(.top, 2)
    }

    /// How many notes in this thread answer `id` directly.
    private func directReplyCount(of id: String) -> Int {
        thread.entries.filter { $0.note.parentEventId == id }.count
    }
}
