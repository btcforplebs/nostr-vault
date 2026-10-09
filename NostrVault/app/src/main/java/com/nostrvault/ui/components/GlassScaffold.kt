package com.nostrvault.ui.components

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.FabPosition
import androidx.compose.material3.Scaffold
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalDensity
import com.nostrvault.ui.theme.WindowBackground

/**
 * Scaffold variant where the toolbar overlays on top of the content
 * with a gradient-fade background, matching iOS toolbarBackground(.hidden).
 *
 * Content scrolls behind the toolbar. The [PaddingValues] passed to
 * [content] includes the measured toolbar height as top padding and the
 * Scaffold bottom padding — callers should apply the top to their
 * scrollable's contentPadding (not the container) so items scroll
 * behind the transparent toolbar.
 */
@Composable
fun GlassScaffold(
    toolbar: @Composable () -> Unit,
    modifier: Modifier = Modifier,
    floatingActionButton: @Composable () -> Unit = {},
    floatingActionButtonPosition: FabPosition = FabPosition.End,
    containerColor: Color = WindowBackground,
    /**
     * Opacity of the fade behind the toolbar, read at draw time. A screen
     * with a header image under the toolbar (a profile banner) fades it in
     * only once content scrolls up behind the buttons.
     */
    toolbarScrimAlpha: () -> Float = { 1f },
    content: @Composable (PaddingValues) -> Unit,
) {
    Scaffold(
        modifier = modifier,
        floatingActionButton = floatingActionButton,
        floatingActionButtonPosition = floatingActionButtonPosition,
        containerColor = containerColor,
    ) { scaffoldPadding ->
        val density = LocalDensity.current
        var toolbarHeightPx by remember { mutableIntStateOf(0) }
        val toolbarTopPadding = with(density) { toolbarHeightPx.toDp() }

        Box(modifier = Modifier.fillMaxSize()) {
            // Content fills full height; caller decides padding placement
            content(
                PaddingValues(
                    top = toolbarTopPadding,
                    bottom = scaffoldPadding.calculateBottomPadding(),
                )
            )

            // Toolbar overlay with gradient fade to transparent
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .onGloballyPositioned { toolbarHeightPx = it.size.height }
                    .drawBehind {
                        val alpha = toolbarScrimAlpha()
                        if (alpha > 0f) {
                            drawRect(
                                Brush.verticalGradient(
                                    colorStops = arrayOf(
                                        0.0f to containerColor,
                                        0.7f to containerColor.copy(alpha = 0.7f),
                                        1.0f to Color.Transparent,
                                    ),
                                ),
                                alpha = alpha.coerceIn(0f, 1f),
                            )
                        }
                    }
                    .align(Alignment.TopCenter),
            ) {
                toolbar()
            }
        }
    }
}
