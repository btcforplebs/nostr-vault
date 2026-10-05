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
/// The fold keeps the newest replies showing — a new reply is what brought the
/// thread back to the top — and hides the earlier ones above them.
struct FeedThreadCard: View {
    let thread: FeedThread<FeedNote>
    /// Which note is open in place. Feed-wide, and owned by the feed, for two
    /// reasons: opening a note has to close whatever the condensed layout
    /// opened — it is one gesture, so it is one selection — and a card
    /// scrolled out of a LazyVStack loses its own `@State`, which would
    /// silently collapse an open note while you were away.
    @Binding var openNoteId: String?
    /// Whether this thread's fold is open. Held by the feed for the same
    /// recycling reason.
    @Binding var isExpanded: Bool
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
    /// No relay returned the root after every fetch pass; say so instead of
    /// loading forever.
    var rootUnavailable: Bool = false
    /// Where each line's top sits in the feed's scroll view, read when a line
    /// is tapped. nil outside the feed.
    var lineTops: ThreadLineTops? = nil
    /// A line was just opened in place; its top was at `y` in the scroll view
    /// before the tap. Opening it closes the note that was open, and when that
    /// note sat above this one — a photo, say — everything below moves up, so
    /// the feed scrolls to hold the tapped line where it was.
    var onOpenedInPlace: ((_ noteId: String, _ y: CGFloat) -> Void)? = nil

    @Environment(\.feedActions) private var actions
    @EnvironmentObject private var configService: ConfigService

    /// Three replies is enough to show a conversation is happening without
    /// letting one thread own the screen.
    private static let collapsedReplyLimit = 3

    private var replies: [FeedThreadEntry<FeedNote>] { thread.replies }

    private var visibleReplies: [FeedThreadEntry<FeedNote>] {
        guard !isExpanded, replies.count > Self.collapsedReplyLimit else { return replies }
        return thread.latestReplies(limit: Self.collapsedReplyLimit)
    }

    private var hiddenReplyCount: Int { replies.count - visibleReplies.count }

    /// A line can only open in place if the caller can supply row data and the
    /// card is interactive at all.
    private var canOpenInPlace: Bool { rowDataFor != nil && onOpen != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let root = thread.root {
                line(for: FeedThreadEntry(note: root, depth: 0), replyCount: directReplyCount(of: root.id))
            } else if !rootUnavailable {
                // A root no relay has, after every pass, gets no line at all:
                // the replies read as posts, rather than every such card
                // announcing what it can't show.
                missingRootHeader
            }

            if hiddenReplyCount > 0 {
                expandButton
            }

            ForEach(visibleReplies) { entry in
                line(for: entry, replyCount: directReplyCount(of: entry.note.id))
            }

            if isExpanded && replies.count > Self.collapsedReplyLimit {
                collapseButton
            }

            // Present whatever the fold is doing: the fold only ever grows
            // this card to the whole conversation, it never leaves the
            // timeline. This is the labelled way to do that — the second tap
            // on an open note reaches the same place but has no label.
            //
            // Only when there is a conversation to open. A reply-less note is
            // its own one-line thread, and most of a Global feed is exactly
            // that — a row reading "Open thread" under every one of them is
            // noise, and it is not even true.
            if !replies.isEmpty, let anchor = threadAnchorNote {
                openThreadRow(for: anchor)
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

    private func line(for entry: FeedThreadEntry<FeedNote>, replyCount: Int) -> some View {
        let id = entry.note.id
        return VStack(alignment: .leading, spacing: 0) {
            // A zero-height marker at the line's top, the target the feed
            // scrolls to. Zero height makes `scrollTo`'s anchor a plain
            // fraction of the viewport, whatever height the line opens to.
            Color.clear
                .frame(height: 0)
                .id(ThreadLineTops.anchorId(for: id))
            if openNoteId == id, let rowDataFor {
                openRow(for: entry, rowData: rowDataFor(entry.note))
            } else {
                condensedLine(for: entry, replyCount: replyCount)
            }
        }
        .onGeometryChange(for: CGFloat.self) {
            $0.frame(in: .named(ThreadLineTops.coordinateSpace)).minY
        } action: { y in
            lineTops?.tops[id] = y
            lineTops?.lineMoved(id, to: y)
        }
    }

    private func condensedLine(for entry: FeedThreadEntry<FeedNote>, replyCount: Int) -> some View {
        let note = entry.note
        // A bare kind-6 repost carries no text: show the note it reposted,
        // credited to its author, as the condensed feed row does.
        let isBareRepost = note.kind == 6 && note.content.isEmpty && note.repostedEventId != nil
        let original = isBareRepost ? rowDataFor?(note).resolvedOriginal : nil
        let shown = original ?? note
        return CondensedNoteLine(
            note: note,
            profile: profileFor(shown.pubkey),
            displayPubkey: original?.pubkey,
            depth: entry.depth,
            style: .plain,
            isFocused: note.id == focusedNoteId,
            replyCount: replyCount,
            contentOverride: contentOverride(for: note, original: original),
            postedAt: original.map { $0.originalCreatedAt ?? $0.createdAt },
            mediaURLs: shown.mediaURLs,
            onProfile: onProfile,
            onTap: tapAction(for: note)
        )
    }

    private func contentOverride(for note: FeedNote, original: FeedNote?) -> String? {
        if let original { return original.kind == 30023 ? original.longFormDisplayTitle : original.content }
        if note.kind == 6 && note.content.isEmpty, let refId = note.repostedEventId {
            return FeedService.shared.unavailableNoteIds.contains(refId)
                ? String(localized: "feed.note.repostUnavailable", defaultValue: "The reposted note is unavailable")
                : String(localized: "feed.note.loadingRepost")
        }
        return note.kind == 30023 ? note.longFormDisplayTitle : nil
    }

    /// The first tap opens a line in place; with no row data to expand into,
    /// it falls back to opening the thread so the line is never a dead target.
    private func tapAction(for note: FeedNote) -> (() -> Void)? {
        guard let onOpen else { return nil }
        guard canOpenInPlace else { return { onOpen(note) } }
        return {
            let y = lineTops?.tops[note.id]
            // No animation: the close above and the scroll that makes up for
            // it land in the same frame, so the tapped line never moves.
            // Animated, the close slid the line up and the scroll slid it
            // back down, two motions for one tap.
            var t = Transaction()
            t.disablesAnimations = true
            if let y { onOpenedInPlace?(note.id, y) }
            lineTops?.justOpened = note.id
            withTransaction(t) { openNoteId = note.id }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [lineTops] in
                if lineTops?.justOpened == note.id { lineTops?.justOpened = nil }
            }
        }
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
                // Same layout as an expanded post in the feed, so tapping to
                // expand looks the same in every view.
                layoutMode: .sideBySide,
                isFocused: note.id == focusedNoteId,
                suppressCardStyling: true,
                // Match the condensed line's own avatar size at this depth so
                // opening a line adds its action bar without the avatar
                // jumping in size — the rail and indent already leave this
                // row less width than a flat feed row gets.
                avatarSize: CondensedNoteLine.avatarSize(forDepth: entry.depth)
            )
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .onTapGesture { onOpen?(note) }
        }
        .padding(.leading, CondensedNoteLine.indentWidth(forDepth: entry.depth))
        // The tap swaps the lines with no motion; the opened note fades in
        // so the swap doesn't read as a cut. Not when it scrolls back in.
        .modifier(OpenRowFade(fades: lineTops?.justOpened == note.id))
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
            title: "Show \(hiddenReplyCount) earlier \(hiddenReplyCount == 1 ? "reply" : "replies")"
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

    /// The note to open the full thread screen on — the root when it has
    /// loaded, otherwise the first reply, so the row still works while the
    /// root is in flight.
    private var threadAnchorNote: FeedNote? {
        thread.root ?? replies.first?.note
    }

    private func openThreadRow(for note: FeedNote) -> some View {
        Button(action: { onOpen?(note) }) {
            HStack(spacing: 6) {
                Text("Open thread")
                    .font(.appSystem(size: 12, weight: .bold, design: .rounded))
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.appSystem(size: 11, weight: .bold))
            }
            .foregroundColor(.secondary)
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            // The gap between "Open thread" and the chevron is part of it.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, 22)
        .disabled(onOpen == nil)
    }

    /// How many notes in this thread answer `id` directly.
    private func directReplyCount(of id: String) -> Int {
        thread.entries.filter { $0.note.parentEventId == id }.count
    }
}

/// The feed's record of where each thread line's top is, in the scroll view's
/// own coordinates. A plain class so the per-frame writes while scrolling
/// don't invalidate the feed.
final class ThreadLineTops {
    static let coordinateSpace = "feedThreadScroll"
    static func anchorId(for noteId: String) -> String { "thread-line-\(noteId)" }

    var tops: [String: CGFloat] = [:]
    var viewportHeight: CGFloat = 0
    /// The line opened by the last tap, which fades in as it appears.
    var justOpened: String?

    /// A line to keep where it was tapped, and the scroll that puts it back.
    /// Run from the line's own geometry change, the first layout pass that
    /// sees it moved, so the correction lands before that frame is shown.
    var hold: (noteId: String, y: CGFloat, restore: () -> Void)?

    func lineMoved(_ noteId: String, to y: CGFloat) {
        guard let hold, hold.noteId == noteId, abs(y - hold.y) > 0.5 else { return }
        self.hold = nil
        hold.restore()
    }
}

/// Fades an opened line in once, as it appears.
private struct OpenRowFade: ViewModifier {
    let fades: Bool
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(!fades || shown ? 1 : 0)
            .onAppear {
                guard fades else { return }
                withAnimation(Motion.media) { shown = true }
            }
    }
}
