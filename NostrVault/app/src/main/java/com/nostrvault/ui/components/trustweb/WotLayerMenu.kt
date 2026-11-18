package com.nostrvault.ui.components

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.MutableTransitionState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
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
import com.nostrvault.data.model.TrustMap
import com.nostrvault.ui.navigation.DockHoldMenuRow
import com.nostrvault.ui.navigation.DockHoldRow
import com.nostrvault.ui.navigation.DockMenuDim
import com.nostrvault.ui.navigation.DockMenuDivider
import com.nostrvault.ui.navigation.DockMenuPanel
import com.nostrvault.ui.navigation.dockMenuEnter
import com.nostrvault.ui.navigation.dockMenuExit
import com.nostrvault.ui.theme.NostrVaultIcons

/**
 * The WOT tab's layer list under its layer pill: the same card, rows, type,
 * dim and spring as the dock hold menu and the feed list (FeedPickerMenu),
 * so the three stay matched. It grows down from the pill's corner. Layers
 * first, each with how many people it holds, then See as a list and Rebuild.
 * Logen 2026-11-18.
 */
@Composable
internal fun WotLayerMenu(
    expanded: Boolean,
    onDismiss: () -> Unit,
    layers: List<TrustMap.Layer>,
    current: TrustMap.Layer,
    counts: Map<TrustMap.Layer, String>,
    onPick: (TrustMap.Layer) -> Unit,
    onList: () -> Unit,
    refreshing: Boolean,
    onRebuild: () -> Unit,
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
                            onClickLabel = "Close layer list",
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
                    layers.forEachIndexed { i, item ->
                        DockHoldMenuRow(
                            spec = DockHoldRow(
                                item.icon,
                                item.title,
                                current = item == current,
                                subtitle = counts[item]?.let { "$it people" },
                            ),
                            hovered = false,
                            onClick = pick { onPick(item) },
                        )
                        if (i == layers.lastIndex) DockMenuDivider()
                    }
                    // Android's list of the layer's people. iOS has no list; it sits
                    // here so the bar has room for the filters.
                    DockHoldMenuRow(
                        spec = DockHoldRow(NostrVaultIcons.PeopleList, "See as a list", current = false),
                        hovered = false,
                        onClick = pick(onList),
                    )
                    DockHoldMenuRow(
                        spec = DockHoldRow(
                            NostrVaultIcons.Refresh,
                            if (refreshing) "Rebuilding…" else "Rebuild your web",
                            current = false,
                        ),
                        hovered = false,
                        // One rebuild at a time: while it runs the row only closes the menu.
                        onClick = if (refreshing) onDismiss else pick(onRebuild),
                    )
                }
            }
        }
    }
}
