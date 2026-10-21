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
import androidx.compose.ui.graphics.Color
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.BorderColor
import androidx.compose.material.icons.outlined.Forum
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil.compose.AsyncImage
import com.nostrvault.data.model.ArticleEngagement
import com.nostrvault.data.model.ArticleEngagementEvent
import com.nostrvault.data.model.ArticleTally
import com.nostrvault.data.model.ArticleHighlight
import com.nostrvault.data.model.ArticleMeta
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.ui.components.AvatarImage
import com.nostrvault.ui.theme.*
import com.nostrvault.data.model.MarkdownParser
import com.nostrvault.ui.components.FullScreenMediaRouter
import java.text.DateFormat

@Composable
internal fun ArticleBody(
    note: FeedNote,
    author: FeedProfile?,
    onProfileClick: (String) -> Unit,
    actions: @Composable () -> Unit,
    onHighlightBlock: ((String) -> Unit)?,
    highlights: List<ArticleHighlight>,
    profiles: Map<String, FeedProfile>,
    onShowHighlights: (List<ArticleHighlight>) -> Unit,
    onCommentHighlight: (ArticleHighlight) -> Unit,
    tally: ArticleTally,
    onOpenComment: (ArticleEngagementEvent) -> Unit,
    gatedArticles: com.nostrvault.service.GatedArticleService? = null,
    modifier: Modifier = Modifier,
) {
    val gated = remember(note.id, note.tags) { com.nostrvault.data.model.GatedArticle.from(note) }
    val meta = remember(note.id, note.tags) { ArticleMeta.from(note) }
    val readMinutes = remember(note.id) { ArticleMeta.readingTimeMinutes(note.content) }
    val blocks = remember(note.content) { MarkdownParser.parse(note.content) }
    // Highlights land on the text blocks only; keys go back to block indexes.
    val placed = remember(blocks, highlights) {
        val textBlocks = blocks.withIndex().mapNotNull { (i, b) -> b.highlightableText?.let { i to it } }
        ArticleEngagement.place(highlights, textBlocks.map { it.second }).mapKeys { textBlocks[it.key].first }
    }
    val colors = LocalNostrVaultColors.current

    Column(modifier = modifier) {
        Spacer(Modifier.height(8.dp))
        meta.imageUrl?.let { url ->
            AsyncImage(
                model = url,
                contentDescription = null,
                contentScale = ContentScale.Crop,
                modifier = Modifier
                    .fillMaxWidth()
                    .height(200.dp)
                    .clip(RoundedCornerShape(12.dp)),
            )
            Spacer(Modifier.height(16.dp))
        }
        Text(
            text = meta.title,
            color = PrimaryText,
            fontSize = 26.sp,
            fontWeight = FontWeight.Bold,
            lineHeight = 32.sp,
        )
        Spacer(Modifier.height(16.dp))
        // iOS: avatar, then name over "date · N min read". Not a link there.
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            AvatarImage(url = author?.pictureURL, pubkey = note.pubkey, size = 28.dp, displayName = author?.bestName)
            Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
                Text(
                    author?.bestName ?: ("npub…" + note.pubkey.takeLast(6)),
                    color = PrimaryText,
                    fontSize = 13.sp,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                )
                Text(
                    text = buildString {
                        append(DateFormat.getDateInstance(DateFormat.MEDIUM).format(meta.publishedAt))
                        // The price stays on Android (Logen): iOS hides it only for an App Store rule.
                        if (gated != null) append(" · 🔒 ${gated.priceSats} sats")
                        else readMinutes?.let { append(" · $it min read") }
                    },
                    color = SecondaryText,
                    fontSize = 11.sp,
                )
            }
        }
        meta.summary?.let {
            Spacer(Modifier.height(16.dp))
            Text(it, color = SecondaryText, fontSize = 15.sp, lineHeight = 21.sp)
            Spacer(Modifier.height(16.dp))
            HorizontalDivider(color = SecondaryText.copy(alpha = 0.2f))
        }
        Spacer(Modifier.height(16.dp))
        actions()
        Spacer(Modifier.height(20.dp))
        val bodyStyle = TextStyle(color = PrimaryText, fontSize = 16.sp, lineHeight = 24.sp)
        if (onHighlightBlock != null) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Icon(Icons.Outlined.BorderColor, contentDescription = null, tint = colors.primary, modifier = Modifier.size(15.dp))
                Text("Tap a paragraph to highlight it", color = colors.primary, fontSize = 13.sp, fontWeight = FontWeight.Medium)
            }
            Spacer(Modifier.height(12.dp))
        }
        if (gated != null && gatedArticles != null) {
            GatedArticleBody(note, gated, gatedArticles, author, bodyStyle)
        } else {
            MarkdownBody(
                blocks = blocks,
                onImageTap = { url -> FullScreenMediaRouter.open(listOf(url), 0) },
                onHighlight = onHighlightBlock,
                highlights = placed,
                onShowHighlights = onShowHighlights,
            )
        }
        if (highlights.isNotEmpty()) {
            Spacer(Modifier.height(24.dp))
            HorizontalDivider(color = SecondaryText.copy(alpha = 0.2f))
            Spacer(Modifier.height(16.dp))
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Icon(Icons.Outlined.BorderColor, contentDescription = null, tint = PrimaryText, modifier = Modifier.size(16.dp))
                Text("Highlights · ${highlights.size}", color = PrimaryText, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
            }
            Spacer(Modifier.height(14.dp))
            Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
                highlights.forEach { h ->
                    HighlightRow(h, profiles[h.pubkey], onComment = { onCommentHighlight(h) })
                }
            }
        }
        Spacer(Modifier.height(24.dp))
        HorizontalDivider(color = SecondaryText.copy(alpha = 0.2f))
        Spacer(Modifier.height(12.dp))
        actions()
        if (tally.commentCount > 0) {
            Spacer(Modifier.height(24.dp))
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Icon(Icons.Outlined.Forum, contentDescription = null, tint = PrimaryText, modifier = Modifier.size(16.dp))
                Text("Comments · ${tally.commentCount}", color = PrimaryText, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
            }
            Spacer(Modifier.height(12.dp))
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                tally.topLevelComments.forEach { comment ->
                    ArticleCommentRow(
                        comment = comment,
                        author = profiles[comment.pubkey],
                        replies = tally.replyCounts[comment.id] ?: 0,
                        profiles = profiles,
                        onProfileClick = onProfileClick,
                        onClick = { onOpenComment(comment) },
                    )
                }
            }
        }
        Spacer(Modifier.height(48.dp))
    }
}

internal val HighlightYellow = Color(0xFFFFD60A)
