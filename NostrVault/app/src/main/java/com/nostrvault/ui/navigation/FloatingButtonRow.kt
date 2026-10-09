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
    /** Every floating button and the mini player: one height, so the two read as one row (iOS buttonHeight). */
    val buttonHeight: Dp = 48.dp
    val miniPlayerHeight: Dp = buttonHeight
    /** The clear space the bottom bar keeps above its pill (its vertical padding). */
    private val barTopPadding: Dp = 12.dp
    /** The row sits this far above the bar's pill (iOS: the inset's 6pt spacing). */
    private val aboveBar: Dp = 6.dp
    /** Before the bar has been measured. */
    private val fallbackBottom: Dp = 84.dp

    /**
     * The row's bottom edge above the screen's bottom: just over the bottom
     * bar's pill, from the bar's measured height (system navigation inset
     * included), as iOS takes it from the measured tab bar. A fixed number
     * here sat the buttons on the bar on the Moto (Logen, 2026-10-05).
     */
    val rowBottom: Dp
        get() = FloatingNavBarInset.height.value
            .takeIf { it > 0.dp }
            ?.let { it - barTopPadding + aboveBar }
            ?: fallbackBottom
    /** Where a Scaffold puts a FAB above its bottom insets (Material3 FabSpacing). */
    private val scaffoldFabSpacing: Dp = 16.dp
    private val scaffoldFabEndInset: Dp = 16.dp
    /** The button's gap from the screen's right edge (iOS trailingInset). */
    private val endInset: Dp = 20.dp
    private val gap: Dp = 10.dp

    private val widths = mutableStateMapOf<Any, Dp>()

    /**
     * How far the mini player's end stays clear of the screen's edge: the
     * widest showing button, its end inset and a gap. Zero with no button.
     */
    val reservedWidth: Dp
        get() = widths.values.maxOrNull()?.let { it + endInset + gap } ?: 0.dp

    internal fun report(key: Any, width: Dp?) {
        if (width == null) widths.remove(key) else widths[key] = width
    }

    /**
     * For a button in a Scaffold's FAB slot: lifts it so its centre is level
     * with the mini player's, and reports its width for as long as it is on
     * screen. The Scaffold already puts the FAB [scaffoldFabSpacing] above
     * the system bar inset, so that is taken off the lift. The Scaffold's
     * 16dp end inset is topped up to [endInset].
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
                // Read here, in layout, so a re-measured bar re-places the button.
                val centre = (rowBottom + miniPlayerHeight / 2).roundToPx()
                val lift = (centre - placeable.height / 2 - scaffoldFabSpacing.roundToPx() - bottomInset)
                    .coerceAtLeast(0)
                val extraEnd = (endInset - scaffoldFabEndInset).roundToPx()
                layout(placeable.width + extraEnd, placeable.height + lift) { placeable.place(0, 0) }
            }
            .onSizeChanged { report(key, with(density) { it.width.toDp() }) }
    }
}
