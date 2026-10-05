package com.nostrvault.ui.navigation

import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.systemBars
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.layout
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/**
 * The row above the tab bar that the music mini player shares with a
 * screen's floating button (Post, Blossom, Dashboard). Each button reports
 * its width here and the mini player stops short of it. The button always
 * sits level with the mini player's spot, playing or not, so the mini player
 * opening or closing never moves it (iOS FloatingButtonRow, #304, Logen
 * 2026-10-05).
 */
object FloatingButtonRow {
    /** The mini player's bottom edge above the screen's bottom while the tab bar shows. */
    val miniPlayerBottom: Dp = 84.dp
    val miniPlayerHeight: Dp = 52.dp
    /** Where a Scaffold puts a FAB above its bottom insets (Material3 FabSpacing). */
    private val scaffoldFabSpacing: Dp = 16.dp
    private val scaffoldFabEndInset: Dp = 16.dp
    private val gap: Dp = 10.dp

    private val widths = mutableStateMapOf<Any, Dp>()

    /**
     * How far the mini player's end stays clear of the screen's edge: the
     * widest showing button, its end inset and a gap. Zero with no button.
     */
    val reservedWidth: Dp
        get() = widths.values.maxOrNull()?.let { it + scaffoldFabEndInset + gap } ?: 0.dp

    internal fun report(key: Any, width: Dp?) {
        if (width == null) widths.remove(key) else widths[key] = width
    }

    /**
     * For a button in a Scaffold's FAB slot: lifts it so its centre is level
     * with the mini player's, and reports its width for as long as it is on
     * screen. The Scaffold already puts the FAB [scaffoldFabSpacing] above
     * the system bar inset, so that is taken off the lift.
     */
    @Composable
    fun Modifier.floatingRowButton(): Modifier {
        val key = remember { Any() }
        DisposableEffect(key) { onDispose { report(key, null) } }
        val density = LocalDensity.current
        val bottomInset = WindowInsets.systemBars.getBottom(density)
        return this
            .layout { measurable, constraints ->
                val placeable = measurable.measure(constraints)
                val centre = (miniPlayerBottom + miniPlayerHeight / 2).roundToPx()
                val lift = (centre - placeable.height / 2 - scaffoldFabSpacing.roundToPx() - bottomInset)
                    .coerceAtLeast(0)
                layout(placeable.width, placeable.height + lift) { placeable.place(0, 0) }
            }
            .onSizeChanged { report(key, with(density) { it.width.toDp() }) }
    }
}
