import SwiftUI

extension FeedView {
    // MARK: - Helper Properties

    /// This feed's built-in compact default: Following defaults OFF, all other
    /// timeline feeds follow the legacy global preference.
    private var defaultCompactForCurrentFeed: Bool {
        switch feedService.feedMode {
        case .following, .articles, .recipes, .marketplace, .live, .reels, .music, .hashtags, .polls:
            return false
        case .discovery, .global, .popular, .media:
            return configService.config.useFeedCompactMode
        }
    }

    /// Only a timeline of notes has replies to gather, so grids and card lists
    /// cycle between expanded and condensed without a threaded stop.
    var currentFeedSupportsThreading: Bool {
        switch feedService.feedMode {
        case .following, .discovery, .global, .popular, .hashtags:
            return true
        case .media, .articles, .recipes, .marketplace, .live, .reels, .music, .polls:
            return false
        }
    }

    /// Whether the layout button has anything to switch. Expanded/condensed
    /// and threaded only change timeline rows (`isCompactModeActive`,
    /// `isThreadedModeActive`); grids, card lists and Reels ignore them, so
    /// the button there cycled an icon and nothing else. The Mac toolbar
    /// already left it out for these feeds.
    var currentFeedHasLayouts: Bool { currentFeedSupportsThreading }

    /// The stored layout for the current feed, migrating anyone who had the
    /// old per-feed compact boolean set.
    var layoutModeForCurrentFeed: FeedLayoutMode {
        FeedLayoutMode.resolve(
            storedLayout: configService.config.feedLayoutModes[feedService.feedMode.rawValue],
            storedCompact: configService.config.feedCompactModes[feedService.feedMode.rawValue],
            defaultCompact: defaultCompactForCurrentFeed
        )
        .clamped(supportsThreading: currentFeedSupportsThreading)
    }

    /// Advance the current feed one step around expanded -> condensed ->
    /// threaded and persist it.
    func cycleLayoutModeForCurrentFeed() {
        setLayoutModeForCurrentFeed(layoutModeForCurrentFeed.next(supportsThreading: currentFeedSupportsThreading))
    }

    /// Jump straight to a layout (used by the overflow menu, where every
    /// choice is visible at once).
    func setLayoutModeForCurrentFeed(_ mode: FeedLayoutMode) {
        let resolved = mode.clamped(supportsThreading: currentFeedSupportsThreading)
        // The note you are looking at, read in the layout you are leaving.
        let readingNoteId = topVisibleNoteId()
        let threadingChanges = (resolved == .threaded) != isThreadedModeActive

        guard !Motion.isReduced else {
            applyLayoutMode(resolved, keeping: readingNoteId, animation: nil)
            return
        }
        if threadingChanges {
            // Rows become whole conversations (or the reverse): nothing to
            // morph, so fade out, swap with the post held at the top, fade in.
            withAnimation(.easeOut(duration: 0.1)) { layoutFadedOut = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                applyLayoutMode(resolved, keeping: readingNoteId, animation: nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    withAnimation(.easeIn(duration: 0.18)) { layoutFadedOut = false }
                }
            }
        } else {
            // Same posts, taller or shorter: each row reshapes in place while
            // the scroll follows the post you were reading.
            applyLayoutMode(resolved, keeping: readingNoteId, animation: .smooth(duration: 0.25))
        }
    }

    private func applyLayoutMode(_ resolved: FeedLayoutMode, keeping readingNoteId: String?, animation: Animation?) {
        pendingLayoutAnimation = animation
        withAnimation(animation) {
        configService.config.feedLayoutModes[feedService.feedMode.rawValue] = resolved.rawValue
        // Keep the legacy key in step so a downgrade still lands somewhere sane.
        configService.config.feedCompactModes[feedService.feedMode.rawValue] = resolved.usesCondensedRows

        // A threaded feed with replies filtered out would show nothing but
        // roots, which is the layout the user just left. Turn replies on with
        // it; the Replies filter still switches them back off.
        var needsRefilter = false
        if resolved == .threaded && !configService.config.showReplies {
            configService.config.showReplies = true
            needsRefilter = true
        }

        configService.save()
        expandedNoteId = nil
        if needsRefilter { feedService.recomputeFilteredNotes() }
        rebuildThreadsIfNeeded(immediate: true)
        }
        if let readingNoteId { pendingLayoutAnchor = rowId(showing: readingNoteId) }
    }

    /// Topmost note on screen. In threaded layout a card is identified by its
    /// root; the first of its notes the flat feed also holds stands in for it.
    private func topVisibleNoteId() -> String? {
        if isThreadedModeActive {
            return feedThreads.first { visibleRows.ids.contains($0.rootId) }?.rootId
        }
        return feedService.filteredNotes.first { visibleRows.ids.contains($0.id) }?.id
    }

    /// The row that shows `noteId` in the layout now active: the thread card
    /// that contains it, or the note itself (or, coming from a thread card,
    /// its first note in the flat feed).
    private func rowId(showing noteId: String) -> String? {
        if isThreadedModeActive {
            return feedThreads.first { thread in
                thread.rootId == noteId || thread.entries.contains { $0.note.id == noteId }
            }?.rootId
        }
        if feedService.filteredNotes.contains(where: { $0.id == noteId }) { return noteId }
        guard let thread = feedThreads.first(where: { $0.rootId == noteId }) else { return nil }
        let flatIds = Set(feedService.filteredNotes.map(\.id))
        return thread.entries.first { flatIds.contains($0.note.id) }?.note.id
    }

    /// Open the thread at a specific note. Threaded rows can't use
    /// `NoteNavigationLink` — one link per line would make the whole card a
    /// stack of links and swallow the fold button — so they route here instead.
    func openNoteDetail(_ note: FeedNote) {
        if let noteDetailSelection {
            noteDetailSelection.select(note)
            return
        }
        #if os(iOS)
        navigationPath.append(note)
        #else
        showingNoteId = note.id
        #endif
    }

    /// Condensed rows are active — either of the two condensed layouts. Media
    /// and article feeds are card/grid layouts with nothing to condense.
    var isCompactModeActive: Bool {
        guard layoutModeForCurrentFeed.usesCondensedRows else { return false }
        switch feedService.feedMode {
        case .following, .discovery, .global, .popular, .hashtags:
            return true
        // Articles and Media are card/grid layouts, not timeline rows —
        // compact mode has nothing to condense. Polls always show the
        // full card, since the vote bars are the point of the feed.
        case .media, .articles, .recipes, .marketplace, .live, .reels, .music, .polls:
            return false
        }
    }

    /// Whole conversations instead of loose rows.
    var isThreadedModeActive: Bool {
        layoutModeForCurrentFeed == .threaded && currentFeedSupportsThreading
    }
}
