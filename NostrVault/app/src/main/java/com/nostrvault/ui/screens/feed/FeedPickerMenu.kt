package com.nostrvault.ui.screens.feed

import androidx.compose.runtime.Composable
import com.nostrvault.data.model.FeedMode
import com.nostrvault.ui.navigation.DockHoldMenuRow
import com.nostrvault.ui.navigation.DockHoldRow
import com.nostrvault.ui.navigation.DockMenuDivider
import com.nostrvault.ui.navigation.DockMenuPopup
import com.nostrvault.ui.theme.NostrVaultIcons

/**
 * The feed list under the header's feed pill: the same card, rows, type,
 * dim and spring as the menu you get holding the Feed tab in the dock
 * (DockMenuPopup, DockHoldMenuRow), so the two stay matched. It grows down
 * from the pill's corner. Feeds first, then Dashboard and Edit Feeds.
 * Logen 2026-11-18: "should look the same as the dock hold menu".
 */
@Composable
internal fun FeedPickerMenu(
    expanded: Boolean,
    onDismiss: () -> Unit,
    modes: List<FeedMode>,
    current: FeedMode,
    onPick: (FeedMode) -> Unit,
    onOpenDashboard: () -> Unit,
    onEditFeeds: () -> Unit,
) {
    DockMenuPopup(expanded = expanded, onDismiss = onDismiss, closeLabel = "Close feed list") {
        val pick = { action: () -> Unit -> { onDismiss(); action() } }
        modes.forEachIndexed { i, mode ->
            DockHoldMenuRow(
                spec = DockHoldRow(mode.icon, mode.displayName, current = mode == current),
                hovered = false,
                onClick = pick { onPick(mode) },
            )
            if (i == modes.lastIndex) DockMenuDivider()
        }
        // Your network's day. Activity only; feed settings are in Settings > Feed.
        DockHoldMenuRow(
            spec = DockHoldRow(NostrVaultIcons.GridLayout, "Dashboard", current = false),
            hovered = false,
            onClick = pick(onOpenDashboard),
        )
        // Last, at the bottom of the list it edits (iOS #303).
        DockHoldMenuRow(
            spec = DockHoldRow(NostrVaultIcons.EditFeeds, "Edit Feeds", current = false),
            hovered = false,
            onClick = pick(onEditFeeds),
        )
    }
}
