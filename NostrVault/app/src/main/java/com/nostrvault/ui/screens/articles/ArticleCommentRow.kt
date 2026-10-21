package com.nostrvault.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.Reply
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.ArticleEngagementEvent
import com.nostrvault.ui.components.AvatarImage
import com.nostrvault.ui.components.NostrContentText
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.ui.theme.*
import android.text.format.DateUtils

/** One comment under an article: who, when, what. Opens as a note, where its replies are. */
@Composable
internal fun ArticleCommentRow(
    comment: ArticleEngagementEvent,
    author: FeedProfile?,
    replies: Int,
    onClick: () -> Unit,
    profiles: Map<String, FeedProfile> = emptyMap(),
    onProfileClick: (String) -> Unit = {},
) {
    val colors = LocalNostrVaultColors.current
    // Media links are dropped from the text, as iOS NostrContentFormatter does.
    val mediaURLs = remember(comment.id) { comment.toNote().mediaURLs.toSet() }
    Column(
        verticalArrangement = Arrangement.spacedBy(6.dp),
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(SecondaryText.copy(alpha = 0.08f))
            .clickable(onClick = onClick)
            .padding(12.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            AvatarImage(url = author?.pictureURL, pubkey = comment.pubkey, size = 24.dp, displayName = author?.bestName)
            Text(
                author?.bestName ?: ("npub…" + comment.pubkey.takeLast(6)),
                color = PrimaryText, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, maxLines = 1,
                modifier = Modifier.weight(1f, fill = false),
            )
            Text(
                DateUtils.getRelativeTimeSpanString(
                    comment.createdAt * 1000, System.currentTimeMillis(), DateUtils.MINUTE_IN_MILLIS,
                ).toString(),
                color = SecondaryText, fontSize = 11.sp, maxLines = 1,
            )
        }
        if (comment.content.isNotBlank()) {
            // Mentions as names, links tappable (iOS ArticleCommentRow formats the text).
            NostrContentText(
                content = comment.content.trim(),
                profiles = profiles,
                mediaURLs = mediaURLs,
                onProfileClick = onProfileClick,
                onPlainTextClick = onClick,
                fontSize = 14.sp,
                lineHeight = 20.sp,
            )
        }
        if (replies > 0) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                Icon(Icons.AutoMirrored.Outlined.Reply, contentDescription = null, tint = colors.primary,
                    modifier = Modifier.size(13.dp))
                Text(if (replies == 1) "1 reply" else "$replies replies", color = colors.primary,
                    fontSize = 12.sp, fontWeight = FontWeight.Medium)
            }
        }
    }
}
