package com.nostrvault.ui.screens.dm

import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.snapshotFlow

/**
 * The keyboard covering the newest messages (B8, NV_MESSAGES_UX_CHECK
 * 2026-11-18): the chat list runs top-down, so when the keyboard lifts the
 * box the list just gets shorter and its bottom slides under it. When the
 * list was at its end and gets shorter, it scrolls by that much, keeping the
 * newest message above the box. Reading older messages, nothing moves.
 */
internal object DMKeyboardFollow {
    /** How far to scroll when the list went from [before] to [after] pixels tall; null for not at all. */
    fun scrollFor(before: Int, after: Int, wasAtEnd: Boolean): Float? =
        if (wasAtEnd && before > 0 && after in 1 until before) (before - after).toFloat() else null

    /** True when the list's last item ends on screen (with a few pixels of slack). */
    fun atEnd(lastVisibleIndex: Int?, total: Int, lastItemEnd: Int, viewportEnd: Int): Boolean =
        total == 0 || (lastVisibleIndex == total - 1 && lastItemEnd <= viewportEnd + 4)
}

/** Keeps the newest message in sight as the keyboard opens ([DMKeyboardFollow]). */
@Composable
internal fun KeepNewestAboveKeyboard(listState: LazyListState) {
    LaunchedEffect(listState) {
        var height = 0
        var atEnd = true
        snapshotFlow { listState.layoutInfo }.collect { info ->
            val now = info.viewportEndOffset - info.viewportStartOffset
            DMKeyboardFollow.scrollFor(height, now, atEnd)?.let { delta -> listState.scrollBy(delta) }
            height = now
            val last = info.visibleItemsInfo.lastOrNull()
            atEnd = DMKeyboardFollow.atEnd(last?.index, info.totalItemsCount, (last?.offset ?: 0) + (last?.size ?: 0), info.viewportEndOffset)
        }
    }
}
