package com.nostrvault.ui.components

import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.foundation.background
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
 * What the globe is waiting on, said in words over it: a spinner, the person
 * when there is one, and a line. [small] for the quieter "wider web" note.
 */
@Composable
internal fun StatusPill(
    text: String,
    accent: Color,
    modifier: Modifier = Modifier,
    pubkey: String? = null,
    profile: FeedProfile? = null,
    small: Boolean = false,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(if (small) 6.dp else 8.dp),
        modifier = modifier
            .padding(horizontal = 24.dp)
            .shadow(8.dp, RoundedCornerShape(50))
            .clip(RoundedCornerShape(50))
            .background(Surface2.copy(alpha = 0.92f))
            .padding(horizontal = if (small) 12.dp else 14.dp, vertical = if (small) 6.dp else 8.dp)
            .semantics(mergeDescendants = true) { liveRegion = LiveRegionMode.Polite },
    ) {
        CircularProgressIndicator(
            color = accent,
            strokeWidth = 1.5.dp,
            modifier = Modifier.size(if (small) 12.dp else 14.dp),
        )
        if (pubkey != null) {
            AvatarImage(url = profile?.pictureURL, pubkey = pubkey, size = 22.dp, displayName = profile?.bestName)
        }
        Text(
            text,
            color = PrimaryText,
            fontSize = if (small) 12.sp else 14.sp,
            fontWeight = FontWeight.Medium,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}
