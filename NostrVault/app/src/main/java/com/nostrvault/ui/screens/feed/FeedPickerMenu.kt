package com.nostrvault.ui.screens.feed

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.MutableTransitionState
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntRect
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Popup
import androidx.compose.ui.window.PopupPositionProvider
import androidx.compose.ui.window.PopupProperties
import com.nostrvault.data.model.FeedMode
import com.nostrvault.ui.navigation.DockHoldMenuRow
import com.nostrvault.ui.navigation.DockHoldRow
import com.nostrvault.ui.navigation.DockMenuDim
import com.nostrvault.ui.navigation.DockMenuDivider
import com.nostrvault.ui.navigation.DockMenuPanel
import com.nostrvault.ui.navigation.dockMenuEnter
import com.nostrvault.ui.navigation.dockMenuExit
import com.nostrvault.ui.theme.NostrVaultIcons

/**
 * The feed list under the header's feed pill: the same card, rows, type,
 * dim and spring as the menu you get holding the Feed tab in the dock
 * (DockMenuPanel, DockHoldMenuRow), so the two stay matched. It grows down
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
    val shown = remember { MutableTransitionState(false) }
    LaunchedEffect(expanded) { shown.targetState = expanded }
    // Kept up through the close animation.
    if (!shown.currentState && !shown.targetState) return

    var anchor by remember { mutableStateOf(IntRect.Zero) }
    val gapPx = with(LocalDensity.current) { 8.dp.roundToPx() }
    // The popup covers the window from its corner, so the dim reaches every
    // edge; the pill's bounds come in the popup's own coordinates.
    val position = remember {
        object : PopupPositionProvider {
            override fun calculatePosition(
                anchorBounds: IntRect, windowSize: IntSize, layoutDirection: LayoutDirection, popupContentSize: IntSize,
            ): IntOffset {
                anchor = anchorBounds
                return IntOffset.Zero
            }
        }
    }
    val origin = TransformOrigin(0f, 0f)
    Popup(
        popupPositionProvider = position,
        onDismissRequest = onDismiss,
        properties = PopupProperties(focusable = true, clippingEnabled = false),
    ) {
        Box(Modifier.fillMaxSize()) {
            AnimatedVisibility(visibleState = shown, enter = fadeIn(tween(140)), exit = fadeOut(tween(140))) {
                Box(
                    Modifier
                        .fillMaxSize()
                        .background(DockMenuDim)
                        .clickable(
                            interactionSource = remember { MutableInteractionSource() },
                            indication = null,
                            onClickLabel = "Close feed list",
                            onClick = onDismiss,
                        ),
                )
            }
            AnimatedVisibility(
                visibleState = shown,
                enter = dockMenuEnter(origin),
                exit = dockMenuExit(origin),
                modifier = Modifier.offset { IntOffset(anchor.left, anchor.bottom + gapPx) },
            ) {
                DockMenuPanel {
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
        }
    }
}
