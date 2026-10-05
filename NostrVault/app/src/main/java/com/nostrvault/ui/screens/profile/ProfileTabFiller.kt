package com.nostrvault.ui.screens.profile

import androidx.compose.foundation.lazy.LazyListLayoutInfo
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/**
 * Blank space after a profile section so the section is at least as tall as
 * the screen. Without it, picking a section with one item shrinks the list
 * below the scroll position, the list clamps, and the tabs drop to the bottom
 * of the screen. iOS #283 gives the section a minimum height; a LazyColumn has
 * no such thing, so this measures the section and makes up the difference.
 */
object ProfileTabFiller {
    const val KEY = "section-filler"

    /** One section item as laid out: its index, top offset and height, in px. */
    data class Item(val index: Int, val offset: Int, val size: Int)

    /** Height of the list's visible content area, without its paddings. */
    fun visibleHeight(info: LazyListLayoutInfo): Int =
        (info.viewportSize.height - info.beforeContentPadding - info.afterContentPadding).coerceAtLeast(0)

    /**
     * The filler height, or null when the section is not all measured yet and
     * the current height should stay. The filler must be the last item.
     */
    fun needed(info: LazyListLayoutInfo, tabsIndex: Int): Int? = needed(
        items = info.visibleItemsInfo.filter { it.key != KEY }.map { Item(it.index, it.offset, it.size) },
        firstSectionIndex = tabsIndex + 1,
        fillerIndex = info.totalItemsCount - 1,
        visibleHeight = visibleHeight(info),
        bottomEdge = info.viewportEndOffset - info.afterContentPadding,
    )

    /**
     * [items] are the laid-out items other than the filler; the section runs
     * from [firstSectionIndex] up to the filler at [fillerIndex].
     */
    fun needed(
        items: List<Item>,
        firstSectionIndex: Int,
        fillerIndex: Int,
        visibleHeight: Int,
        bottomEdge: Int,
    ): Int? {
        if (visibleHeight <= 0) return null
        val lastSectionIndex = fillerIndex - 1
        if (lastSectionIndex < firstSectionIndex) return visibleHeight
        // The section runs on below the screen: it is tall enough as it is,
        // and anything past what's showing hasn't been measured.
        val last = items.firstOrNull { it.index == lastSectionIndex } ?: return null
        val lastBottom = last.offset + last.size
        val first = items.firstOrNull { it.index == firstSectionIndex }
        val shortBy = if (first != null) {
            visibleHeight - (lastBottom - first.offset)
        } else {
            // The section's top has scrolled away, so it is taller than what
            // shows; fill to the bottom of the screen and no further.
            bottomEdge - lastBottom
        }
        return shortBy.coerceAtLeast(0)
    }

    /** Room a tab needs to show its icon and a count [chars] long beside it. */
    fun tabWidthWithCount(chars: Int): Dp = (17 + 4 + 7 * chars + 4).dp
}
