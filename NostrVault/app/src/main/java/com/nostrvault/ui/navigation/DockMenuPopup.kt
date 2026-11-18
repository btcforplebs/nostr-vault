package com.nostrvault.ui.navigation

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

/**
 * A header pill's drop-down in the dock hold menu's look: the dim behind, and
 * [DockMenuPanel] springing down from the pill's corner. Place it in the same
 * Box as the pill; [content] is the rows ([DockHoldMenuRow], [DockMenuDivider]).
 * The feed and Vault headers use it, so they and the dock menu stay matched.
 */
@Composable
internal fun DockMenuPopup(
    expanded: Boolean,
    onDismiss: () -> Unit,
    closeLabel: String,
    content: @Composable () -> Unit,
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
                            onClickLabel = closeLabel,
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
                DockMenuPanel { content() }
            }
        }
    }
}
