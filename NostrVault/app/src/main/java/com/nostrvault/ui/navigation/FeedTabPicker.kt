package com.nostrvault.ui.navigation

import androidx.compose.runtime.Composable
import androidx.compose.runtime.Stable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import com.nostrvault.data.model.FeedMenuSettings
import com.nostrvault.data.model.FeedMode
import com.nostrvault.ui.screens.feed.icon
import kotlinx.coroutines.flow.MutableStateFlow

/**
 * Hold the Feed tab, slide onto a feed, let go: that feed opens. Let go
 * anywhere else and it cancels; a plain tap is still the Feed tab. The
 * gesture and the menu are the shared dock engine ([DockHoldMenu]); this is
 * the Feed's side of it. iOS: FeedHoldPicker.swift (#239, #1505).
 */
@Stable
object FeedTabPicker {
    /** The menu, lined up with the Feed tab's left edge. */
    val menu = DockHoldMenu<FeedMode>()

    val isOpen: Boolean get() = menu.isOpen

    /** The feed on screen, reported by the feed; drives the checkmark. */
    var shownMode by mutableStateOf<FeedMode?>(null)

    /**
     * A pick waiting for the feed screen to apply it. The feed's mode lives in
     * its own ViewModel, which may not exist yet when the pick is made from
     * another tab, so it is held here until the feed takes it.
     */
    val request = MutableStateFlow<FeedMode?>(null)

    /** In the reader's order, hidden feeds left out (Edit Feeds, iOS #303). */
    val order: List<FeedMode> get() = FeedMenuSettings.menuModes()
}

/** The row under [point], with 12dp-ish horizontal slack (kept for the hit test). */
internal fun feedModeAt(rows: Map<FeedMode, Rect>, point: Offset, slackPx: Float = 36f): FeedMode? =
    dockRowAt(rows, point, slackPx, 0f)

/** The Feed menu, over the whole window above the bar. */
@Composable
fun FeedTabPickerOverlay(
    onPick: (FeedMode) -> Unit,
    modifier: Modifier = Modifier,
) {
    // Subscribed, so an edit shows the next time the menu opens.
    val menuStored by FeedMenuSettings.stored.collectAsState()
    val order = remember(menuStored) { FeedMenuSettings.menuModes(menuStored) }
    DockHoldMenuOverlay(
        menu = FeedTabPicker.menu,
        items = order,
        row = { mode -> DockHoldRow(mode.icon, mode.displayName, current = FeedTabPicker.shownMode == mode) },
        closeLabel = "Close feed list",
        onPick = onPick,
        modifier = modifier,
    )
}
