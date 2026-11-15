package com.nostrvault.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.zIndex
import com.nostrvault.ui.theme.SecondaryGroupedBg
import com.nostrvault.ui.theme.Surface2
import com.nostrvault.ui.theme.lightOr

/**
 * Displays a row of overlapping circular avatars, matching the iOS Vault design.
 * Used in the inline engagement bar to show who engaged with a note.
 *
 * @param pubkeys List of hex pubkeys to show avatars for (max 3)
 * @param profiles Map of pubkey to profile for fetching avatar URLs
 * @param size Size of each avatar (default 16.dp to match iOS)
 * @param overlapOffset Negative offset for overlapping effect (default -4.dp)
 * @param borderWidth Width of border around each avatar (default 1.dp)
 * @param borderColor Color of border (default SecondaryGroupedBg)
 */
@Composable
fun OverlappingAvatars(
    pubkeys: List<String>,
    profiles: Map<String, com.nostrvault.data.model.FeedProfile>,
    modifier: Modifier = Modifier,
    size: Dp = 16.dp,
    overlapOffset: Dp = (-4).dp,
    borderWidth: Dp = 1.dp,
    borderColor: Color = SecondaryGroupedBg,
) {
    val displayPubkeys = pubkeys.take(3)

    if (displayPubkeys.isEmpty()) return

    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier,
    ) {
        displayPubkeys.forEachIndexed { index, pubkey ->
            Box(
                modifier = Modifier
                    .offset(x = overlapOffset * index)
                    .zIndex((displayPubkeys.size - index).toFloat())
                    .size(size)
                    .border(borderWidth, borderColor, CircleShape)
                    .clip(CircleShape)
                    .background(lightOr(Surface2, Color(0xFF1A1A1E))),
            ) {
                AvatarImage(
                    url = profiles[pubkey]?.pictureURL,
                    pubkey = pubkey,
                    size = size,
                    displayName = profiles[pubkey]?.bestName,
                    modifier = Modifier.clip(CircleShape),
                )
            }
        }
    }
}
