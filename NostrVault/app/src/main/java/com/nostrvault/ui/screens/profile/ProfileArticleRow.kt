package com.nostrvault.ui.screens.profile

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil.compose.AsyncImage
import com.nostrvault.ui.theme.*

/** One of this person's articles: cover, title, summary and date. Opens the reader. */
@Composable
internal fun ProfileArticleRow(note: com.nostrvault.data.model.FeedNote, onClick: () -> Unit) {
    val meta = remember(note.id, note.tags) { com.nostrvault.data.model.ArticleMeta.from(note) }
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 14.dp),
    ) {
        meta.imageUrl?.let { url ->
            AsyncImage(
                model = url,
                contentDescription = null,
                contentScale = ContentScale.Crop,
                modifier = Modifier
                    .fillMaxWidth()
                    .height(140.dp)
                    .clip(RoundedCornerShape(10.dp)),
            )
            Spacer(Modifier.height(10.dp))
        }
        Text(
            text = meta.title,
            color = PrimaryText,
            fontSize = 17.sp,
            fontWeight = FontWeight.SemiBold,
            lineHeight = 22.sp,
            maxLines = 2,
            overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
        )
        meta.summary?.let {
            Spacer(Modifier.height(6.dp))
            Text(
                text = it,
                color = SecondaryText,
                fontSize = 14.sp,
                lineHeight = 19.sp,
                maxLines = 3,
                overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
            )
        }
        Spacer(Modifier.height(8.dp))
        Text(
            text = buildString {
                append(java.text.DateFormat.getDateInstance(java.text.DateFormat.MEDIUM).format(meta.publishedAt))
                com.nostrvault.data.model.ArticleMeta.readingTimeMinutes(note.content)?.let { append(" · $it min read") }
            },
            color = TertiaryText,
            fontSize = 12.sp,
        )
    }
}
