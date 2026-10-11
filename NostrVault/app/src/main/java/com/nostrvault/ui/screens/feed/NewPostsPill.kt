package com.nostrvault.ui.screens.feed

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.LocalIndication
import androidx.compose.foundation.indication
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.*

// ── New posts pill ──────────────────────────────────────────────

@Composable
internal fun NewPostsPill(
    count: Int,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    /** The small "↑ N" pill the folded top bar shows in the button's place. */
    compact: Boolean = false,
) {
    val colors = LocalNostrVaultColors.current
    // Mirrors iOS: Capsule fill(havenPurple/theme primary), white content,
    // soft offset drop shadow (black 40%, radius 8, y+4), 10/20 padding,
    // arrow.up size 12 bold + "N New Posts" size 13 bold. Compact: 5/10
    // padding, radius 4 / y+2 shadow, arrow 11 + count 12 (99+ at most).
    val shape = RoundedCornerShape(50)
    // Tapped anywhere in the box, rippled on the capsule.
    val interaction = remember { MutableInteractionSource() }
    Box(
        modifier = modifier
            .semantics(mergeDescendants = true) { contentDescription = "$count new posts, tap to load" }
            // The small pill's tap target, without growing the pill.
            .clickable(interactionSource = interaction, indication = null, onClick = onClick)
            .padding(if (compact) 8.dp else 0.dp),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .shadow(
                    elevation = if (compact) 4.dp else 8.dp,
                    shape = shape,
                    ambientColor = Color.Black.copy(alpha = 0.4f),
                    spotColor = Color.Black.copy(alpha = 0.4f),
                )
                .clip(shape)
                .background(colors.primary)
                .indication(interaction, LocalIndication.current)
                .padding(
                    vertical = if (compact) 5.dp else 10.dp,
                    horizontal = if (compact) 10.dp else 20.dp,
                ),
        ) {
            Icon(
                imageVector = NostrVaultIcons.ArrowUp,
                contentDescription = null,
                tint = PrimaryText,
                modifier = Modifier.size(if (compact) 11.dp else 12.dp),
            )
            Spacer(Modifier.width(if (compact) 4.dp else 8.dp))
            Text(
                text = if (compact) (if (count > 99) "99+" else "$count") else "$count New Posts",
                fontWeight = FontWeight.Bold,
                fontSize = if (compact) 12.sp else 13.sp,
                color = PrimaryText,
            )
        }
    }
}
