package com.nostrvault.ui.components

import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.Surface2

/**
 * What the globe is waiting on, said in words over it: the person when there
 * is one, a white spinner, and a line. iOS `statusPill`.
 */
@Composable
internal fun StatusPill(
    text: String,
    modifier: Modifier = Modifier,
    pubkey: String? = null,
    profile: FeedProfile? = null,
) {
    val shape = RoundedCornerShape(50)
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        modifier = modifier
            .padding(horizontal = 24.dp)
            .shadow(14.dp, shape, ambientColor = Color.Black.copy(alpha = 0.45f), spotColor = Color.Black.copy(alpha = 0.45f))
            .clip(shape)
            // The card's fill (iOS material is the theme lane's call), with iOS's 0.14 stroke.
            .background(Surface2.copy(alpha = 0.92f))
            .border(1.dp, Color.White.copy(alpha = 0.14f), shape)
            .padding(start = if (pubkey == null) 14.dp else 6.dp, end = 16.dp, top = 8.dp, bottom = 8.dp)
            .semantics(mergeDescendants = true) { liveRegion = LiveRegionMode.Polite },
    ) {
        if (pubkey != null) {
            AvatarImage(url = profile?.pictureURL, pubkey = pubkey, size = 28.dp, displayName = profile?.bestName)
        }
        CircularProgressIndicator(color = Color.White, strokeWidth = 2.dp, modifier = Modifier.size(16.dp))
        Text(
            text,
            color = PrimaryText,
            fontSize = 14.sp,
            fontWeight = FontWeight.SemiBold,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}
