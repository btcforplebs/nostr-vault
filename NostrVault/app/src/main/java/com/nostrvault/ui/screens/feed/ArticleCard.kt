package com.nostrvault.ui.screens.feed

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
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
import com.nostrvault.data.model.ArticleMeta
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.GatedArticle
import com.nostrvault.data.model.GatedArticleTeaser
import com.nostrvault.ui.components.AvatarImage
import com.nostrvault.ui.components.NostrWebLinks
import com.nostrvault.ui.theme.*
import java.text.DateFormat

/** The article's `t` tags, lowercased, as iOS LongFormMetadata.topics; a card shows the first [limit]. */
internal fun articleTopics(tags: List<List<String>>, limit: Int = 3): List<String> =
    tags.filter { it.size >= 2 && it[0] == "t" && it[1].isNotBlank() }
        .map { it[1].lowercase() }
        .take(limit)

/** What a byline calls an author: their name, else "npub…" and the key's last six (iOS ArticleCardView). */
internal fun articleAuthorName(profile: FeedProfile?, pubkey: String): String =
    profile?.bestName ?: ("npub…" + pubkey.takeLast(6))

/**
 * One row in the Articles feed (iOS ArticleCardView): full-bleed hero image,
 * title, a preview that falls back to the top of the body, up to three topic
 * chips, and a byline whose avatar opens the author's profile. Long-press
 * offers the article on the web.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
internal fun ArticleCard(
    note: FeedNote,
    profile: FeedProfile?,
    onClick: () -> Unit,
    onAuthorClick: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = LocalNostrVaultColors.current
    val context = LocalContext.current
    val meta = remember(note.id, note.tags) { ArticleMeta.from(note) }
    val gated = remember(note.id, note.tags) { GatedArticle.from(note) != null }
    val topics = remember(note.id, note.tags) { articleTopics(note.tags) }
    // The body's opening is enough for a three-line preview; a 20,000-word
    // article is never stripped whole to draw a row.
    val preview = remember(note.id) {
        ArticleMeta.previewText(meta.summary, GatedArticleTeaser.previewBody(note).take(4000))
    }
    val readMinutes = remember(note.id) { if (gated) null else ArticleMeta.readingTimeMinutes(note.content) }
    val webLink = remember(note.id) { NostrWebLinks.forEvent(note.kind, note.pubkey, note.tags) }
    var menuOpen by remember { mutableStateOf(false) }
    val shape = RoundedCornerShape(14.dp)

    Box(modifier = modifier) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .clip(shape)
                .background(SecondaryGroupedBg)
                .border(0.5.dp, SeparatorColor, shape)
                .combinedClickable(
                    onClick = onClick,
                    onLongClick = if (webLink != null) ({ menuOpen = true }) else null,
                ),
        ) {
            meta.imageUrl?.let { url ->
                AsyncImage(
                    model = url,
                    contentDescription = null,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier.fillMaxWidth().height(160.dp),
                )
            }
            Column(
                verticalArrangement = Arrangement.spacedBy(8.dp),
                modifier = Modifier.padding(14.dp),
            ) {
                Text(
                    text = meta.title,
                    color = PrimaryText,
                    fontSize = 18.sp,
                    fontWeight = FontWeight.Bold,
                    lineHeight = 23.sp,
                    maxLines = 3,
                    overflow = TextOverflow.Ellipsis,
                )
                preview?.let {
                    Text(
                        text = it,
                        color = SecondaryText,
                        fontSize = 14.sp,
                        lineHeight = 19.sp,
                        maxLines = 3,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                if (topics.isNotEmpty()) {
                    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        topics.forEach { topic ->
                            Text(
                                text = topic,
                                color = colors.primary,
                                fontSize = 10.sp,
                                fontWeight = FontWeight.SemiBold,
                                maxLines = 1,
                                modifier = Modifier
                                    .clip(CircleShape)
                                    .background(colors.primaryPale)
                                    .padding(horizontal = 8.dp, vertical = 3.dp),
                            )
                        }
                    }
                }
                ArticleByline(note, profile, meta, gated, readMinutes, onAuthorClick)
            }
        }
        DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
            webLink?.let { link ->
                DropdownMenuItem(
                    text = { Text(link.label) },
                    leadingIcon = { Icon(NostrVaultIcons.OpenExternal, contentDescription = null) },
                    onClick = {
                        menuOpen = false
                        NostrWebLinks.open(context, link.url)
                    },
                )
            }
        }
    }
}

@Composable
private fun ArticleByline(
    note: FeedNote,
    profile: FeedProfile?,
    meta: ArticleMeta,
    gated: Boolean,
    readMinutes: Int?,
    onAuthorClick: (String) -> Unit,
) {
    val colors = LocalNostrVaultColors.current
    val name = articleAuthorName(profile, note.pubkey)
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        AvatarImage(
            url = profile?.pictureURL,
            pubkey = note.pubkey,
            size = 22.dp,
            displayName = profile?.bestName,
            modifier = Modifier.clip(CircleShape).clickable(onClickLabel = name) { onAuthorClick(note.pubkey) },
        )
        Text(
            name,
            color = SecondaryText,
            fontSize = 12.sp,
            fontWeight = FontWeight.SemiBold,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f, fill = false),
        )
        Text("·", color = SecondaryText, fontSize = 12.sp)
        Text(
            DateFormat.getDateInstance(DateFormat.MEDIUM).format(meta.publishedAt),
            color = SecondaryText,
            fontSize = 12.sp,
            maxLines = 1,
        )
        if (gated) {
            Text("·", color = SecondaryText, fontSize = 12.sp)
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(3.dp)) {
                Icon(NostrVaultIcons.Lock, contentDescription = null, tint = colors.primary, modifier = Modifier.size(12.dp))
                Text("Locked", color = colors.primary, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, maxLines = 1)
            }
        } else if (readMinutes != null) {
            Text("·", color = SecondaryText, fontSize = 12.sp)
            Text("$readMinutes min read", color = SecondaryText, fontSize = 12.sp, maxLines = 1)
        }
    }
}
