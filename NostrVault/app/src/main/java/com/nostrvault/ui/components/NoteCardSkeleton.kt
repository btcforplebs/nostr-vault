package com.nostrvault.ui.components

import androidx.compose.animation.core.*
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import com.nostrvault.ui.theme.*

/**
 * Shimmer skeleton placeholder matching NoteCard layout.
 * A light band sweeps across the bars where content will appear.
 */
@Composable
fun NoteCardSkeleton(
    modifier: Modifier = Modifier,
) {
    val colors = LocalNostrVaultColors.current

    // A light band sweeps left to right across every bar. Under Reduce Motion
    // `Motion.shimmer` is null and the bars hold still at 0.7, not at a dim
    // start value: the placeholder still has to be legible as one once it has
    // stopped moving.
    val shimmerColor = skeletonShimmerBrush()

    Surface(
        shape = RoundedCornerShape(12.dp),
        color = SecondaryGroupedBg.copy(alpha = 0.85f),
        border = BorderStroke(0.8.dp, colors.primary.copy(alpha = 0.12f)),
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 10.dp, vertical = 4.dp),
    ) {
        Column(
            modifier = Modifier.padding(14.dp),
        ) {
            // Author header skeleton
            Row(
                verticalAlignment = Alignment.CenterVertically,
            ) {
                // Avatar circle
                Box(
                    modifier = Modifier
                        .size(40.dp)
                        .clip(CircleShape)
                        .background(shimmerColor),
                )

                Spacer(Modifier.width(10.dp))

                Column {
                    // Name
                    Box(
                        modifier = Modifier
                            .width(100.dp)
                            .height(12.dp)
                            .clip(RoundedCornerShape(4.dp))
                            .background(shimmerColor),
                    )
                    Spacer(Modifier.height(6.dp))
                    // Timestamp
                    Box(
                        modifier = Modifier
                            .width(60.dp)
                            .height(10.dp)
                            .clip(RoundedCornerShape(4.dp))
                            .background(shimmerColor),
                    )
                }
            }

            Spacer(Modifier.height(12.dp))

            // Content text skeleton (3 rows), full width like the card's text
            Column {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(12.dp)
                        .clip(RoundedCornerShape(4.dp))
                        .background(shimmerColor),
                )
                Spacer(Modifier.height(6.dp))
                Box(
                    modifier = Modifier
                        .fillMaxWidth(0.85f)
                        .height(12.dp)
                        .clip(RoundedCornerShape(4.dp))
                        .background(shimmerColor),
                )
                Spacer(Modifier.height(6.dp))
                Box(
                    modifier = Modifier
                        .fillMaxWidth(0.6f)
                        .height(12.dp)
                        .clip(RoundedCornerShape(4.dp))
                        .background(shimmerColor),
                )
            }

            Spacer(Modifier.height(12.dp))

            // Engagement bar skeleton
            Row(
                horizontalArrangement = Arrangement.SpaceBetween,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(start = 50.dp),
            ) {
                repeat(5) {
                    Box(
                        modifier = Modifier
                            .size(18.dp)
                            .clip(CircleShape)
                            .background(shimmerColor),
                    )
                }
            }
        }
    }
}

/**
 * The skeleton bars' fill: a band sweeping across, or a still 0.7 alpha under
 * Reduce Motion. One sweep per [SWEEP_MS], restarting from the left.
 */
@Composable
private fun skeletonShimmerBrush(): Brush {
    val still = TertiaryText.copy(alpha = 0.7f)
    if (Motion.shimmer == null) return SolidColor(still)
    val bandPx = with(LocalDensity.current) { SWEEP_BAND.toPx() }
    val travelPx = with(LocalDensity.current) { LocalConfiguration.current.screenWidthDp.dp.toPx() } + 2 * bandPx
    val transition = rememberInfiniteTransition(label = "skeleton")
    val progress by transition.animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(tween(SWEEP_MS, easing = LinearEasing), RepeatMode.Restart),
        label = "skeletonSweep",
    )
    val x = progress * travelPx - bandPx
    val dim = TertiaryText.copy(alpha = 0.35f)
    return Brush.linearGradient(
        colors = listOf(dim, still, dim),
        start = Offset(x, 0f),
        end = Offset(x + bandPx, 0f),
    )
}

private const val SWEEP_MS = 1200
private val SWEEP_BAND = 160.dp

/**
 * Shows a column of skeleton loading cards.
 */
@Composable
fun SkeletonFeed(
    count: Int = 5,
    modifier: Modifier = Modifier,
) {
    Column(modifier = modifier) {
        repeat(count) {
            NoteCardSkeleton()
        }
    }
}

/**
 * A placeholder bar exactly one text line tall in the given style, so a
 * skeleton built from these is the height the loaded text will be and the row
 * does not grow when it arrives. The bar is inset vertically so stacked lines
 * read as separate lines rather than one block.
 */
@Composable
internal fun SkeletonTextLine(
    fontSize: TextUnit,
    widthFraction: Float,
    color: Color,
    modifier: Modifier = Modifier,
    lineHeight: TextUnit = TextUnit.Unspecified,
    fontWeight: FontWeight? = null,
) {
    Text(
        text = " ",
        fontSize = fontSize,
        lineHeight = lineHeight,
        fontWeight = fontWeight,
        maxLines = 1,
        modifier = modifier
            .fillMaxWidth(widthFraction)
            .drawBehind {
                val inset = minOf(3.dp.toPx(), size.height / 4)
                drawRoundRect(
                    color = color,
                    topLeft = Offset(0f, inset),
                    size = Size(size.width, size.height - 2 * inset),
                    cornerRadius = CornerRadius(4.dp.toPx()),
                )
            },
    )
}
