package com.nostrvault.ui.screens.feed

import androidx.compose.foundation.lazy.LazyListState
import com.nostrvault.data.model.FeedNote

/**
 * Opens a note in the condensed feed. Opening one closes the note that was
 * open; when that sat above, it shrank and everything under it slid up with
 * it, the tapped row too, as far as off screen. The tapped row is held where
 * it was tapped instead (iOS `FeedView.toggleExpandedNote`, PR #1258): the
 * close and the scroll that makes up for it land in the same layout pass.
 *
 * [rowId] is the tapped row's list key; [open] changes the open note.
 */
internal fun LazyListState.openHoldingTappedRow(
    rowId: String,
    openId: String?,
    notes: List<FeedNote>,
    open: () -> Unit,
) {
    val tapped = layoutInfo.visibleItemsInfo.firstOrNull { it.key == rowId }
    val openIndex = openId?.let { id -> notes.indexOfFirst { it.id == id } }
    val hold = tapped?.let { heldTapPosition(openIndex, it.index, it.offset) }
    open()
    // A negative offset places the row that far below the list's top; the
    // list stops at its first row if there is not that much above it.
    hold?.let { (index, offset) -> requestScrollToItem(index, offset) }
}

/**
 * The (index, scroll offset) that keeps the row at [tappedIndex], [tappedOffset]
 * px below the list's top, in place while the open row at [openIndex] closes.
 * Null when no open row above it closes.
 */
internal fun heldTapPosition(openIndex: Int?, tappedIndex: Int, tappedOffset: Int): Pair<Int, Int>? =
    if (openIndex != null && openIndex in 0 until tappedIndex) tappedIndex to -tappedOffset else null
