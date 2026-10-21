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
import com.nostrvault.ui.theme.*
import dev.jeziellago.compose.markdowntext.MarkdownText
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
    val blocks = remember(note.content) { ArticleEngagement.blocks(note.content) }
    val placed = remember(blocks, highlights) { ArticleEngagement.place(highlights, blocks) }
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
                    .height(180.dp)
                    .clip(RoundedCornerShape(12.dp)),
            )
            Spacer(Modifier.height(16.dp))
        }
        Text(
            text = meta.title,
            color = PrimaryText,
            fontSize = 24.sp,
            fontWeight = FontWeight.Bold,
            lineHeight = 30.sp,
        )
        Spacer(Modifier.height(8.dp))
        Text(
            text = buildString {
                append(author?.bestName ?: note.pubkey.take(8))
                append(" · ")
                append(DateFormat.getDateInstance(DateFormat.MEDIUM).format(meta.publishedAt))
                if (gated != null) append(" · 🔒 ${gated.priceSats} sats")
                else readMinutes?.let { append(" · $it min read") }
            },
            color = SecondaryText,
            fontSize = 13.sp,
            modifier = Modifier.clickable { onProfileClick(note.pubkey) },
        )
        meta.summary?.let {
            Spacer(Modifier.height(12.dp))
            Text(it, color = SecondaryText, fontSize = 15.sp, lineHeight = 21.sp)
        }
        Spacer(Modifier.height(16.dp))
        actions()
        Spacer(Modifier.height(20.dp))
        val bodyStyle = TextStyle(color = PrimaryText, fontSize = 16.sp, lineHeight = 24.sp)
        if (gated != null && gatedArticles != null) {
            GatedArticleBody(note, gated, gatedArticles, author, bodyStyle)
        } else if (onHighlightBlock == null && placed.isEmpty()) {
            MarkdownText(
                markdown = note.content,
                style = bodyStyle,
                linkColor = colors.primary,
                modifier = Modifier.fillMaxWidth(),
            )
        } else if (onHighlightBlock == null) {
            // Block by block, so a passage other people highlighted gets a
            // soft yellow tint and a count that opens who highlighted it.
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                blocks.forEachIndexed { index, block ->
                    val shown = placed[index]
                    if (shown == null) {
                        MarkdownText(markdown = block, style = bodyStyle, linkColor = colors.primary,
                            modifier = Modifier.fillMaxWidth())
                    } else {
                        Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(4.dp)) {
                            MarkdownText(
                                markdown = block,
                                style = bodyStyle,
                                linkColor = colors.primary,
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clip(RoundedCornerShape(8.dp))
                                    .background(HighlightYellow.copy(alpha = 0.16f))
                                    .padding(horizontal = 8.dp, vertical = 6.dp),
                            )
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(4.dp),
                                modifier = Modifier
                                    .clip(RoundedCornerShape(50))
                                    .background(HighlightYellow.copy(alpha = 0.16f))
                                    .clickable(onClickLabel = if (shown.size == 1) "1 highlight" else "${shown.size} highlights") {
                                        onShowHighlights(shown)
                                    }
                                    .padding(horizontal = 10.dp, vertical = 4.dp),
                            ) {
                                Icon(Icons.Outlined.BorderColor, contentDescription = null, tint = SecondaryText,
                                    modifier = Modifier.size(13.dp))
                                Text("${shown.size}", color = SecondaryText, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                            }
                        }
                    }
                }
            }
        } else {
            // Highlight mode: one tappable block per paragraph, tinted so the
            // reader can see what a tap will pick up.
            Text("Tap a paragraph to highlight it", color = colors.primary, fontSize = 13.sp, fontWeight = FontWeight.Medium)
            Spacer(Modifier.height(12.dp))
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                blocks.forEach { block ->
                    Text(
                        text = ArticleEngagement.plainText(block),
                        color = PrimaryText,
                        fontSize = 16.sp,
                        lineHeight = 24.sp,
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(8.dp))
                            .background(colors.primary.copy(alpha = 0.08f))
                            .clickable { onHighlightBlock(ArticleEngagement.plainText(block)) }
                            .padding(horizontal = 8.dp, vertical = 6.dp),
                    )
                }
            }
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
                        onClick = { onOpenComment(comment) },
                    )
                }
            }
        }
        Spacer(Modifier.height(48.dp))
    }
}

internal val HighlightYellow = Color(0xFFFFD60A)
