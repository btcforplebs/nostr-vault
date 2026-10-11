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
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.*
import com.nostrvault.ui.components.*
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.flow.*
import java.util.*

/** One "below the fold" response: who, what kind, and the text. */
@Composable
internal fun OtherResponseCard(note: FeedNote, profile: FeedProfile?, onClick: () -> Unit) {
    val label = when (note.kind) {
        1 -> "Quoted"
        9802 -> "Highlighted"
        1244 -> "Voice reply"
        else -> "Responded"
    }
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 4.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(SecondaryText.copy(alpha = 0.08f))
            .clickable(enabled = note.kind == 1, onClick = onClick)
            .padding(12.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            AvatarImage(url = profile?.pictureURL, pubkey = note.pubkey, size = 22.dp, displayName = profile?.bestName)
            Spacer(Modifier.width(8.dp))
            Text(
                text = profile?.bestName ?: note.pubkey.take(8),
                color = PrimaryText, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, maxLines = 1,
            )
            Spacer(Modifier.width(8.dp))
            Text(label, color = SecondaryText, fontSize = 11.sp, fontWeight = FontWeight.SemiBold)
        }
        if (note.content.isNotBlank()) {
            Spacer(Modifier.height(6.dp))
            Text(
                text = note.content,
                color = PrimaryText,
                fontSize = 14.sp,
                maxLines = if (note.kind == 9802) 6 else 4,
                overflow = TextOverflow.Ellipsis,
                fontStyle = if (note.kind == 9802) FontStyle.Italic else FontStyle.Normal,
            )
        }
    }
}
