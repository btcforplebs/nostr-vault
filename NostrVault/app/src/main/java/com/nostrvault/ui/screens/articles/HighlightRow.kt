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
import androidx.compose.material.icons.outlined.ChatBubbleOutline
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.ArticleHighlight
import com.nostrvault.ui.components.AvatarImage
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.ui.theme.*
import android.text.format.DateUtils

/** One person's highlight: who, the passage, their comment if any, and a reply button. */
@Composable
internal fun HighlightRow(highlight: ArticleHighlight, author: FeedProfile?, onComment: () -> Unit) {
    val name = author?.bestName ?: ("npub…" + highlight.pubkey.takeLast(6))
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            AvatarImage(url = author?.pictureURL, pubkey = highlight.pubkey, size = 22.dp, displayName = author?.bestName)
            Text(name, color = PrimaryText, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
            Text(
                DateUtils.getRelativeTimeSpanString(
                    highlight.createdAt * 1000, System.currentTimeMillis(), DateUtils.MINUTE_IN_MILLIS,
                ).toString(),
                color = SecondaryText,
                fontSize = 11.sp,
            )
        }
        Row(modifier = Modifier.height(IntrinsicSize.Min)) {
            Box(
                Modifier
                    .width(3.dp)
                    .fillMaxHeight()
                    .clip(RoundedCornerShape(2.dp))
                    .background(HighlightYellow.copy(alpha = 0.8f)),
            )
            Spacer(Modifier.width(8.dp))
            Text(
                highlight.passage,
                color = PrimaryText,
                fontSize = 14.sp,
                lineHeight = 20.sp,
                fontStyle = androidx.compose.ui.text.font.FontStyle.Italic,
            )
        }
        highlight.comment?.let {
            Text(it, color = SecondaryText, fontSize = 14.sp, lineHeight = 20.sp)
        }
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            modifier = Modifier
                .padding(start = 11.dp)
                .clip(RoundedCornerShape(50))
                .background(SecondaryText.copy(alpha = 0.1f))
                .clickable(onClick = onComment)
                .padding(horizontal = 10.dp, vertical = 5.dp),
        ) {
            Icon(Icons.Outlined.ChatBubbleOutline, contentDescription = null, tint = SecondaryText, modifier = Modifier.size(13.dp))
            Text("Comment", color = SecondaryText, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
        }
    }
}
