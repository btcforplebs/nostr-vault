package com.nostrvault.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.LocalOledMode
import com.nostrvault.ui.theme.SecondaryGroupedBg

/**
 * Glass pill, circle, and rect modifiers matching the iOS LiquidGlassModifier.
 *
 * iOS uses .glassEffect(.regular, in: .capsule) on iOS 26+, with a
 * fallback of ultraThinMaterial + gradient overlay + accent tint + shadow.
 * On Android we approximate this with a semi-transparent background,
 * theme accent tint, gradient highlight, thin border, and drop shadow.
 *
 * Layer order (matching iOS fallback):
 *   1. Drop shadow
 *   2. Semi-transparent dark base
 *   3. Theme accent tint (primary @ 6%)
 *   4. Top-to-center highlight gradient
 *   5. Gradient border stroke (0.5dp)
 *   6. Clip to shape
 */

// ─── Shape tokens ────────────────────────────────────────────────

private val PillShape = RoundedCornerShape(50)

// ─── OLED-aware value helpers ────────────────────────────────────

/**
 * Background alpha: nearly solid. iOS glass blurs what is behind it; Compose
 * cannot, so at 0.55 the feed's text read straight through the bars and the
 * Following pill (Logen, Moto). Higher on OLED to compensate for true-black.
 */
private fun glassBgAlpha(isOled: Boolean): Float =
    if (isOled) 0.94f else 0.92f

/** Border top alpha (matches iOS 0.25 / OLED ~0.30). */
private fun glassBorderTopAlpha(isOled: Boolean): Float =
    if (isOled) 0.30f else 0.25f

/** Border bottom alpha (matches iOS 0.08 / OLED ~0.12). */
private fun glassBorderBottomAlpha(isOled: Boolean): Float =
    if (isOled) 0.12f else 0.08f

/** Circle border top alpha (iOS applyGlassCircle: 0.15 / OLED 0.30). */
private fun glassCircleBorderTopAlpha(isOled: Boolean): Float =
    if (isOled) 0.35f else 0.25f

/** Circle border bottom alpha. */
private fun glassCircleBorderBottomAlpha(isOled: Boolean): Float =
    if (isOled) 0.15f else 0.08f

// ─── Highlight gradient (top → center, matching iOS) ─────────────

private val HighlightGradient = Brush.verticalGradient(
    colorStops = arrayOf(
        0.0f to Color.White.copy(alpha = 0.12f),
        0.5f to Color.Transparent,
    ),
)

// ─── Modifier extensions ─────────────────────────────────────────

/**
 * Modifier that applies a frosted-glass pill background.
 */
fun Modifier.glassPillBackground(
    isOled: Boolean = false,
    accentColor: Color = Color.Transparent,
): Modifier = this
    .shadow(
        elevation = 8.dp,
        shape = PillShape,
        ambientColor = Color.Black.copy(alpha = 0.12f),
        spotColor = Color.Black.copy(alpha = 0.12f),
    )
    .background(SecondaryGroupedBg.copy(alpha = glassBgAlpha(isOled)), PillShape)
    .background(accentColor.copy(alpha = 0.06f), PillShape)
    .background(HighlightGradient, PillShape)
    .border(
        width = 0.5.dp,
        brush = Brush.verticalGradient(
            listOf(
                Color.White.copy(alpha = glassBorderTopAlpha(isOled)),
                Color.White.copy(alpha = glassBorderBottomAlpha(isOled)),
            ),
        ),
        shape = PillShape,
    )
    .clip(PillShape)

/**
 * Modifier that applies a frosted-glass circle background.
 */
fun Modifier.glassCircleBackground(
    isOled: Boolean = false,
    accentColor: Color = Color.Transparent,
): Modifier = this
    .shadow(
        elevation = 8.dp,
        shape = CircleShape,
        ambientColor = Color.Black.copy(alpha = 0.15f),
        spotColor = Color.Black.copy(alpha = 0.15f),
    )
    .background(SecondaryGroupedBg.copy(alpha = glassBgAlpha(isOled)), CircleShape)
    .background(accentColor.copy(alpha = 0.06f), CircleShape)
    .background(HighlightGradient, CircleShape)
    .border(
        width = 0.5.dp,
        brush = Brush.verticalGradient(
            listOf(
                Color.White.copy(alpha = glassCircleBorderTopAlpha(isOled)),
                Color.White.copy(alpha = glassCircleBorderBottomAlpha(isOled)),
            ),
        ),
        shape = CircleShape,
    )
    .clip(CircleShape)

/**
 * Modifier that applies a frosted-glass rounded-rectangle background.
 * Matches iOS applyGlassRect(cornerRadius:).
 */
fun Modifier.glassRectBackground(
    cornerRadius: Dp = 16.dp,
    isOled: Boolean = false,
    accentColor: Color = Color.Transparent,
): Modifier {
    val shape = RoundedCornerShape(cornerRadius)
    return this
        .shadow(
            elevation = 8.dp,
            shape = shape,
            ambientColor = Color.Black.copy(alpha = 0.15f),
            spotColor = Color.Black.copy(alpha = 0.15f),
        )
        .background(SecondaryGroupedBg.copy(alpha = glassBgAlpha(isOled)), shape)
        .background(accentColor.copy(alpha = 0.06f), shape)
        .background(HighlightGradient, shape)
        .border(
            width = 0.5.dp,
            brush = Brush.verticalGradient(
                listOf(
                    Color.White.copy(alpha = glassBorderTopAlpha(isOled)),
                    Color.White.copy(alpha = glassBorderBottomAlpha(isOled)),
                ),
            ),
            shape = shape,
        )
        .clip(shape)
}

// ─── Composable containers ───────────────────────────────────────

/**
 * A row container with frosted-glass pill background.
 * Reads OLED mode and theme accent from CompositionLocals.
 */
@Composable
fun GlassPill(
    modifier: Modifier = Modifier,
    horizontalArrangement: Arrangement.Horizontal = Arrangement.spacedBy(4.dp),
    content: @Composable RowScope.() -> Unit,
) {
    val isOled = LocalOledMode.current
    val accentColor = LocalNostrVaultColors.current.primary
    Row(
        modifier = modifier
            .glassPillBackground(isOled = isOled, accentColor = accentColor)
            .padding(horizontal = 6.dp, vertical = 4.dp),
        horizontalArrangement = horizontalArrangement,
        verticalAlignment = Alignment.CenterVertically,
        content = content,
    )
}

/**
 * A circular frosted-glass container.
 * Reads OLED mode and theme accent from CompositionLocals.
 */
@Composable
fun GlassCircle(
    modifier: Modifier = Modifier,
    size: Dp = 32.dp,
    content: @Composable () -> Unit,
) {
    val isOled = LocalOledMode.current
    val accentColor = LocalNostrVaultColors.current.primary
    Box(
        modifier = modifier
            .size(size)
            .glassCircleBackground(isOled = isOled, accentColor = accentColor),
        contentAlignment = Alignment.Center,
    ) {
        content()
    }
}

/**
 * A rounded-rectangle frosted-glass container.
 * Matches iOS applyGlassRect(cornerRadius:).
 */
@Composable
fun GlassRect(
    modifier: Modifier = Modifier,
    cornerRadius: Dp = 16.dp,
    content: @Composable () -> Unit,
) {
    val isOled = LocalOledMode.current
    val accentColor = LocalNostrVaultColors.current.primary
    Box(
        modifier = modifier.glassRectBackground(
            cornerRadius = cornerRadius,
            isOled = isOled,
            accentColor = accentColor,
        ),
    ) {
        content()
    }
}
