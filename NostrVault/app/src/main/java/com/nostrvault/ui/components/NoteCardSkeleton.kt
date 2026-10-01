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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import com.nostrvault.ui.theme.*

/**
 * Shimmer skeleton placeholder matching NoteCard layout.
 * Shows animated pulsing rectangles where content will appear.
 */
@Composable
fun NoteCardSkeleton(
    modifier: Modifier = Modifier,
) {
    val colors = LocalNostrVaultColors.current

    // Under Reduce Motion `Motion.shimmer` is null, and the skeleton simply
    // holds still at the bright end of its range. Note that it holds at 0.7 and
    // not at the 0.5 midpoint: the placeholder still has to be legible as a
    // placeholder once it has stopped breathing. Skipping the animation must
    // never mean skipping the value — an unanimated alpha left at the 0.3
    // initialValue would strand every skeleton at near-invisible.
    val shimmerSpec = Motion.shimmer
    val alpha = if (shimmerSpec == null) {
        0.7f
    } else {
        val infiniteTransition = rememberInfiniteTransition(label = "skeleton")
        val animated by infiniteTransition.animateFloat(
            initialValue = 0.3f,
            targetValue = 0.7f,
            animationSpec = shimmerSpec,
            label = "skeletonAlpha",
        )
        animated
    }

    val shimmerColor = TertiaryText.copy(alpha = alpha)

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

            // Content text skeleton (3 rows)
            Column(modifier = Modifier.padding(start = 50.dp)) {
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
