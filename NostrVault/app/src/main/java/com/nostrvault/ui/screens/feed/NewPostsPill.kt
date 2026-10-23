package com.nostrvault.ui.screens.feed

import androidx.compose.animation.AnimatedVisibility
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
import com.nostrvault.ui.notification.PillSize
import com.nostrvault.ui.notification.PillStyle
import com.nostrvault.ui.notification.rememberHidesAmbient
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
    // An ambient pill (docs/pills.md): the lane's accent capsule, regular
    // size since it takes taps, hidden while the lane shows an error, result
    // or feedback pill. Compact: 5/10 padding, radius 4 / y+2 shadow, arrow
    // 11 + count 12 (99+ at most), in the folded bar's row.
    val shape = PillStyle.shape
    val size = if (compact) PillSize.SMALL else PillSize.REGULAR
    // Tapped anywhere in the box, rippled on the capsule.
    val interaction = remember { MutableInteractionSource() }
    val (pillEnter, pillExit) = Motion.pillTransition
    // The caller's modifier (its alignment in the feed's Box) goes on the
    // outermost node: inside AnimatedVisibility an align is ignored and the
    // pill sat at the left edge.
    AnimatedVisibility(visible = !rememberHidesAmbient(), enter = pillEnter, exit = pillExit, modifier = modifier) {
    Box(
        modifier = Modifier
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
                    vertical = if (compact) 5.dp else size.vertical,
                    horizontal = if (compact) 10.dp else size.horizontal,
                ),
        ) {
            Icon(
                imageVector = NostrVaultIcons.ArrowUp,
                contentDescription = null,
                tint = PillStyle.textColor,
                modifier = Modifier.size(size.icon),
            )
            Spacer(Modifier.width(if (compact) 4.dp else 8.dp))
            Text(
                text = if (compact) (if (count > 99) "99+" else "$count") else "$count New Posts",
                fontWeight = FontWeight.Bold,
                fontSize = size.font,
                color = PillStyle.textColor,
                // Digits keep their width as the count changes (iOS .monospacedDigit()).
                style = androidx.compose.ui.text.TextStyle(fontFeatureSettings = "tnum"),
            )
        }
    }
    }
}
