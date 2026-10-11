package com.nostrvault.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil.compose.AsyncImage
import coil.request.ImageRequest
import com.nostrvault.data.model.ArticleMeta
import com.nostrvault.data.model.FeedNote
import androidx.compose.ui.semantics.contentDescription
import com.nostrvault.ui.theme.*

/**
 * A kind-30023 article inside a feed row: cover, title, "Article · N min
 * read", and the summary (or the top of the body, Markdown stripped). Tapping
 * opens the reader. The row above already draws the author and the time, so
 * this is not the Articles feed's own card. iOS ArticleInlineBody.
 */
@Composable
internal fun ArticleInlineBody(
    note: FeedNote,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val meta = remember(note.id, note.tags) { ArticleMeta.from(note) }
    val preview = remember(note.id) { ArticleMeta.previewText(meta.summary, note.content) }
    val minutes = remember(note.id) { ArticleMeta.readingTimeMinutes(note.content) }
    val accent = LocalNostrVaultColors.current.primary
    Column(
        verticalArrangement = Arrangement.spacedBy(8.dp),
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .clickable(onClickLabel = "Read article", onClick = onClick),
    ) {
        meta.imageUrl?.let { url ->
            AsyncImage(
                model = ImageRequest.Builder(LocalContext.current)
                    .data(url)
                    .size(800)
                    .crossfade(100)
                    .build(),
                contentDescription = null,
                contentScale = ContentScale.Crop,
                modifier = Modifier
                    .fillMaxWidth()
                    .height(140.dp)
                    .clip(RoundedCornerShape(10.dp))
                    .background(TertiaryGroupedBg),
            )
        }
        Text(
            text = meta.title,
            color = PrimaryText,
            fontSize = 18.sp,
            fontWeight = FontWeight.Bold,
            lineHeight = 23.sp,
            maxLines = 3,
            overflow = TextOverflow.Ellipsis,
        )
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(
                imageVector = NostrVaultIcons.Articles,
                contentDescription = null,
                tint = accent,
                modifier = Modifier.size(11.dp),
            )
            Spacer(Modifier.width(6.dp))
            Text(
                text = if (minutes != null) "Article · $minutes min read" else "Article",
                color = accent,
                fontSize = 11.sp,
                fontWeight = FontWeight.SemiBold,
            )
        }
        preview?.let {
            Text(
                text = it,
                color = SecondaryText,
                fontSize = 15.sp,
                lineHeight = 20.sp,
                maxLines = 3,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}
