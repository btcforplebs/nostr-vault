package com.nostrvault.ui.components

import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/**
 * The one line a tapped post's top lands on, in note detail and the feed:
 * [UNDER_BUTTONS] below the bottom of the top bar's buttons (Logen 10-28).
 * Opened replies and root notes in detail, and posts opened in the feed,
 * all put their avatar and action row at the same screen point.
 *
 * Both top bars end [BAR_PAD_UNDER_BUTTONS] below their pills, so the line is
 * [BELOW_TOOLBAR] below the toolbar height GlassScaffold reports. Lists add it
 * to their top padding: the first row sits on the line at rest, and
 * `scrollToItem(index, 0)` puts any row there.
 */
object TapAnchor {
    val UNDER_BUTTONS: Dp = 20.dp
    val BAR_PAD_UNDER_BUTTONS: Dp = 8.dp
    val BELOW_TOOLBAR: Dp = UNDER_BUTTONS - BAR_PAD_UNDER_BUTTONS

    /**
     * Room under the last row so any row can reach the line: the viewport
     * less the list's top and bottom padding. A row that tall or taller
     * below the opened one is always enough, whatever the row's height.
     */
    fun roomBelow(viewport: Dp, topPadding: Dp, bottomPadding: Dp, min: Dp = 0.dp): Dp =
        (viewport - topPadding - bottomPadding).coerceAtLeast(min)
}
