package com.nostrvault.ui.screens.feed

import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.runtime.*
import com.nostrvault.data.model.FeedMode
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.FeedThread
import com.nostrvault.ui.navigation.FeedTabPicker
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.withContext

// FeedScreen's effects, one per job (iOS FeedView's .task / .onChange handlers). State that an effect reads inside a
// snapshotFlow or a long-running collector is passed as a getter, not a value: the getter reads FeedScreen's State
// each time, as the effect did when it lived inline, so it still sees every change without restarting.

/** Fetch the parents and quoted notes the feed's rows point at but the cache doesn't have. */
@Composable
internal fun FeedMissingNotesEffects(notes: List<FeedNote>, viewModel: FeedViewModel) {
    // Batch-fetch all missing parent notes whenever the visible notes list changes.
    // One REQ with all IDs instead of one REQ per item. The scan walks the
    // whole feed (up to MAX_FEED_NOTES), so it runs off the main thread;
    // only the fetch call comes back to it.
    LaunchedEffect(notes) {
        val missingIds = withContext(Dispatchers.Default) {
            // The fetch below first looks the ids up in the feed (iOS #302);
            // building that index here keeps a 10k-note pass off Main.
            viewModel.warmNoteIndex()
            notes.flatMap { note ->
                // A bare repost's row shows the note it points at.
                listOfNotNull(note.parentEventId, note.repostedEventId?.takeIf { note.isBareRepost })
                    .filter { viewModel.parentNoteFor(it) == null }
            }.distinct()
        }
        if (missingIds.isNotEmpty()) {
            // The fetch adopts parents already in the feed first, which is a
            // lookup per id over the index; off Main like the scan above.
            withContext(Dispatchers.Default) { viewModel.fetchMissingParentNotes(missingIds) }
        }
    }

    // Batch-fetch any embedded quoted notes (nostr:note1.../nevent1...) referenced
    // by the visible notes. Decoded to hex and fetched via the same path as parents.
    // Once they resolve, fetch their authors' profiles if not already cached —
    // collected here rather than keyed on the cache, so a resolving quote does
    // not recompose the screen.
    LaunchedEffect(notes) {
        val quotedIds = withContext(Dispatchers.Default) {
            notes.flatMap { it.quotedEventIds }.distinct()
        }
        if (quotedIds.isEmpty()) return@LaunchedEffect
        withContext(Dispatchers.Default) { viewModel.fetchMissingQuotedNotes(quotedIds) }
        viewModel.parentNotesCache.collect {
            viewModel.fetchMissingQuotedProfiles(quotedIds)
        }
    }
}

/** Scrolling state for the feed service, and the cold-boot scroll restore. */
@Composable
internal fun FeedScrollTrackingEffects(listState: LazyListState, notes: List<FeedNote>, viewModel: FeedViewModel) {
    // Tell the feed when a drag or fling is moving the list, so incoming
    // relay batches wait for it to settle instead of reshaping the list under
    // the finger; and save the scroll position for snapshot persistence when
    // it stops. Read through snapshotFlow, not as an effect key: a key read
    // here recomposed the whole screen at the start and end of every fling.
    LaunchedEffect(listState) {
        snapshotFlow { listState.isScrollInProgress }.collect { scrolling ->
            viewModel.setFeedScrolling(scrolling)
            if (!scrolling) {
                viewModel.saveScrollPosition(
                    listState.firstVisibleItemIndex,
                    listState.firstVisibleItemScrollOffset,
                )
            }
        }
    }
    DisposableEffect(Unit) {
        onDispose { viewModel.setFeedScrolling(false) }
    }

    // Restore scroll position from disk snapshot on cold boot
    val restoredPosition by viewModel.restoredScrollPosition.collectAsState()
    LaunchedEffect(restoredPosition, notes) {
        val pos = restoredPosition ?: return@LaunchedEffect
        if (notes.isNotEmpty() && pos.index < notes.size) {
            listState.scrollToItem(pos.index, pos.offset)
            viewModel.clearRestoredPosition()
        }
    }
}

/** Show waiting posts by themselves when the list is at the top and auto-load is on. */
@Composable
internal fun FeedAutoApplyEffect(
    viewModel: FeedViewModel,
    pendingCount: () -> Int,
    autoLoad: () -> Boolean,
    isAtTop: () -> Boolean,
) {
    // Auto-apply pending notes when at top with auto-load enabled.
    // Uses snapshotFlow so that rapid pendingCount changes don't restart
    // the effect (unlike LaunchedEffect with pendingCount as a key).
    LaunchedEffect(Unit) {
        snapshotFlow { pendingCount() > 0 && autoLoad() && isAtTop() }
            .collect { shouldApply ->
                if (shouldApply) {
                    // Brief debounce to batch rapid arrivals
                    delay(150)
                    // Re-check — user may have scrolled away during debounce
                    if (isAtTop()) {
                        // The reveal effect below performs the scroll once the
                        // prepend has actually landed in the list — scrolling
                        // here (even after a fixed delay) races composition and
                        // strands the new post above the viewport.
                        viewModel.applyPendingNotes()
                    }
                }
            }
    }
}

/** Bring prepended posts fully into view when the list is at the top. */
@Composable
internal fun FeedRevealEffect(
    listState: LazyListState,
    isThreaded: () -> Boolean,
    feedThreads: () -> List<FeedThread>,
    notes: () -> List<FeedNote>,
    isAtTop: () -> Boolean,
) {
    // iOS-parity reveal. The keyed LazyColumn anchors the previous top item
    // whenever notes are prepended, which strands the new notes above the
    // viewport (only their bottom edge peeks out behind the translucent
    // toolbar) — SwiftUI's ScrollView doesn't anchor, so iOS reveals new
    // posts naturally. Watching the first note id is the only reliable
    // signal that a prepend has actually composed; fixed delays race the
    // filter-recompute debounce and the frame clock. When the first id
    // changes while the user is (or just was) at the top, scroll to the
    // absolute top so the new post lands fully in view below the toolbar.
    // Also covers replies, which insert directly and bypass pendingNotes.
    // Threaded mode lists thread cards, not notes: a reply moves its card to
    // the top without changing notes' first id, so watch the first key the
    // list actually renders.
    LaunchedEffect(Unit) {
        var prevFirstId: String? = null
        var wasAtTop = true
        snapshotFlow {
            val keys = if (isThreaded()) feedThreads().map { it.rootId } else notes().map { it.id }
            keys to isAtTop()
        }
            .collect { (keys, atTop) ->
                val firstId = keys.firstOrNull()
                // Prepend = first key changed but the old first item is still
                // in the list (a refresh/reload replaces it entirely).
                val prepended = firstId != null && prevFirstId != null &&
                    firstId != prevFirstId && prevFirstId in keys
                if (prepended && (wasAtTop || atTop)) {
                    // requestScrollToItem wins over the next layout's key
                    // anchoring. animateScrollToItem could run before that
                    // layout, see index 0, do nothing, and leave the new
                    // item above the viewport.
                    listState.requestScrollToItem(0)
                }
                prevFirstId = firstId
                wasAtTop = atTop
            }
    }
}

/** The Feed tab: its hold-to-pick menu, and a second tap (scroll to top, or refresh when already there). */
@Composable
internal fun FeedTabEffects(
    feedMode: FeedMode,
    viewModel: FeedViewModel,
    listState: LazyListState,
    hashtagsListState: LazyListState,
    hashtagsViewModel: HashtagsFeedViewModel,
    isAtTop: () -> Boolean,
) {
    // Hold-the-Feed-tab picker (iOS #239): it shows this feed's mode and
    // hands its pick here, where the mode lives.
    LaunchedEffect(feedMode) { FeedTabPicker.shownMode = feedMode }
    LaunchedEffect(Unit) {
        FeedTabPicker.request.filterNotNull().collect { mode ->
            FeedTabPicker.request.value = null
            if (mode != viewModel.feedMode.value) viewModel.setFeedMode(mode)
        }
    }

    // Handle tab re-selection: scroll to top or refresh if already at top
    LaunchedEffect(Unit) {
        viewModel.scrollToTopRequest.collect {
            // Reels has no list to scroll, and the untouched list below it
            // always reads as "at top" — a reselect must not wipe the viewer's
            // place by refreshing.
            if (viewModel.feedMode.value == FeedMode.REELS) return@collect
            if (viewModel.feedMode.value == FeedMode.HASHTAGS) {
                if (hashtagsListState.firstVisibleItemIndex == 0 && hashtagsListState.firstVisibleItemScrollOffset == 0) {
                    hashtagsViewModel.reload()
                } else {
                    hashtagsListState.scrollToItem(0)
                }
                return@collect
            }
            if (isAtTop()) {
                viewModel.refresh()
            } else {
                listState.scrollToItem(0) // Instant scroll for better performance
            }
        }
    }
}
