import SwiftUI

/// One conversation in the feed: a root note plus its replies, drawn as a
/// single card of condensed lines rather than one card per note.
///
/// A tap means exactly what it means in the feed's other condensed layout:
/// the first tap opens that line in place into the full note with its action
/// bar, a second tap on the open note goes to the thread. Replying is one tap
/// from the timeline, and the gesture is the same one whichever condensed
/// layout you are in.
///
/// Replies past `collapsedReplyLimit` stay folded so a long argument can't take
/// over the timeline; the fold opens in place instead of pushing a new screen.
struct FeedThreadCard: View {
    let thread: FeedThread<FeedNote>
    let profileFor: (String) -> FeedProfile?
    /// Resolves the row data a full note needs. Required for the expanded row;
    /// without it a line has nothing to expand into and stays condensed.
    var rowDataFor: ((FeedNote) -> FeedNoteRowData)? = nil
    var focusedNoteId: String? = nil
    /// Opens the thread at a given note — the second tap, on an already-open
    /// note. nil makes the lines non-interactive, which the enclosing
    /// navigation link relies on.
    var onOpen: ((FeedNote) -> Void)? = nil
    var onReply: ((FeedNote) -> Void)? = nil
    var onQuote: ((FeedNote) -> Void)? = nil
    var onProfile: ((String) -> Void)? = nil
    var onMedia: ((URL, [URL]) -> Void)? = nil

    @State private var isExpanded = false
    @State private var openNoteId: String?
    @Environment(\.feedActions) private var actions
    @EnvironmentObject private var configService: ConfigService

    /// Three replies is enough to show a conversation is happening without
    /// letting one thread own the screen.
    private static let collapsedReplyLimit = 3

    private var replies: [FeedThreadEntry<FeedNote>] { thread.replies }

    private var visibleReplies: [FeedThreadEntry<FeedNote>] {
        guard !isExpanded, replies.count > Self.collapsedReplyLimit else { return replies }
        return Array(replies.prefix(Self.collapsedReplyLimit))
    }

    private var hiddenReplyCount: Int { replies.count - visibleReplies.count }

    /// A line can only open in place if the caller can supply row data and the
    /// card is interactive at all.
    private var canOpenInPlace: Bool { rowDataFor != nil && onOpen != nil }

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
        .animation(Motion.panel, value: openNoteId)
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
        if openNoteId == entry.note.id, let rowDataFor {
            openRow(for: entry, rowData: rowDataFor(entry.note))
        } else {
            condensedLine(for: entry, replyCount: replyCount)
        }
    }

    private func condensedLine(for entry: FeedThreadEntry<FeedNote>, replyCount: Int) -> some View {
        let note = entry.note
        return CondensedNoteLine(
            note: note,
            profile: profileFor(note.pubkey),
            depth: entry.depth,
            style: .plain,
            isFocused: note.id == focusedNoteId,
            replyCount: replyCount,
            contentOverride: note.kind == 30023 ? note.longFormDisplayTitle : nil,
            mediaURLs: note.mediaURLs,
            onProfile: onProfile,
            onTap: tapAction(for: note)
        )
    }

    /// The first tap opens a line in place; with no row data to expand into,
    /// it falls back to opening the thread so the line is never a dead target.
    private func tapAction(for note: FeedNote) -> (() -> Void)? {
        guard let onOpen else { return nil }
        guard canOpenInPlace else { return { onOpen(note) } }
        return { openNoteId = note.id }
    }

    /// A line opened in place: the full note, its action bar, and the same
    /// rail and indent the condensed line had, so nothing shifts sideways
    /// under the tap. Tapping it again goes to the thread.
    private func openRow(for entry: FeedThreadEntry<FeedNote>, rowData: FeedNoteRowData) -> some View {
        let note = entry.note
        return HStack(alignment: .top, spacing: 0) {
            if entry.depth > 0 {
                CondensedNoteLine.rail(isOLED: configService.config.useOLED)
            }

            FeedNoteRow(
                note: note,
                profile: profileFor(note.pubkey),
                rowData: rowData,
                onReply: { onReply?(note) },
                onQuote: { onQuote?(note) },
                onProfile: onProfile,
                onMedia: onMedia,
                // The rail already says what this answers, and the card owns
                // the chrome — a second card inside it reads as a mistake.
                showParent: false,
                layoutMode: .wide,
                isFocused: note.id == focusedNoteId,
                suppressCardStyling: true
            )
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .onTapGesture { onOpen?(note) }
        }
        .padding(.leading, CondensedNoteLine.indentWidth(forDepth: entry.depth))
        .transition(.opacity)
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
