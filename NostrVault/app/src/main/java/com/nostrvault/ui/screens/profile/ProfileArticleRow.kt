package com.nostrvault.ui.screens.profile

import androidx.compose.foundation.background
import androidx.compose.foundation.border
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
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil.compose.AsyncImage
import coil.request.ImageRequest
import com.nostrvault.data.model.ArticleMeta
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.GatedArticle
import com.nostrvault.data.model.GatedArticleTeaser
import com.nostrvault.ui.components.AvatarImage
import com.nostrvault.ui.components.NostrWebLinks
import com.nostrvault.ui.theme.*
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map

/** What an article card says, worked out from the note alone. iOS ArticleCardView. */
internal object ProfileArticleCardText {
    /** The first three `t` tags, lowercased, as iOS `LongFormMetadata.topics.prefix(3)`. */
    fun topics(tags: List<List<String>>): List<String> =
        tags.filter { it.size >= 2 && it[0] == "t" && it[1].isNotBlank() }
            .map { it[1].lowercase() }
            .distinct()
            .take(3)

    /** The author's own summary, or the top of the body (a gated article's teaser) with the Markdown stripped. */
    fun preview(note: FeedNote, summary: String?): String? =
        ArticleMeta.previewText(summary, GatedArticleTeaser.previewBody(note))

    /** The name under the card: the profile's, or iOS's `npub…` + the key's last six. */
    fun authorName(bestName: String?, pubkey: String): String = bestName ?: ("npub…" + pubkey.takeLast(6))
}

/**
 * One of this person's articles as iOS draws it on the profile
 * (`ArticleCardView`): a rounded card with the cover across the top, then
 * title, summary, up to three topics and author · date · reading time (or
 * Locked). Opens the reader; a long-press offers "Open in …" on the web,
 * as iOS's `openInWebContextMenu`.
 */
@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
internal fun ProfileArticleRow(note: FeedNote, onClick: () -> Unit) {
    val colors = LocalNostrVaultColors.current
    val meta = remember(note.id, note.tags) { ArticleMeta.from(note) }
    val preview = remember(note.id, note.tags) { ProfileArticleCardText.preview(note, meta.summary) }
    val topics = remember(note.id, note.tags) { ProfileArticleCardText.topics(note.tags) }
    val locked = remember(note.id, note.tags) { GatedArticle.from(note) != null }
    val minutes = remember(note.id) { ArticleMeta.readingTimeMinutes(note.content) }
    val nostrService = rememberProfileContentServices().nostrService()
    val author by remember(note.pubkey) {
        nostrService.profiles.map { it[note.pubkey] }.distinctUntilChanged()
    }.collectAsState(initial = nostrService.profiles.value[note.pubkey])
    val cardShape = RoundedCornerShape(14.dp)
    val context = LocalContext.current
    val haptics = androidx.compose.ui.platform.LocalHapticFeedback.current
    val webLink = remember(note.id, note.tags) { NostrWebLinks.forEvent(note.kind, note.pubkey, note.tags) }
    var menuOpen by remember(note.id) { mutableStateOf(false) }

    // iOS lays the cards out 12 apart inside 16 of padding.
    Column(
        modifier = Modifier
            .padding(horizontal = 16.dp, vertical = 6.dp)
            .fillMaxWidth()
            .clip(cardShape)
            .background(SecondaryGroupedBg)
            .border(0.5.dp, SeparatorColor, cardShape)
            .combinedClickable(
                onClickLabel = "Read article",
                onClick = onClick,
                onLongClick = webLink?.let {
                    {
                        haptics.performHapticFeedback(androidx.compose.ui.hapticfeedback.HapticFeedbackType.LongPress)
                        menuOpen = true
                    }
                },
                onLongClickLabel = webLink?.label,
            ),
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
                    .height(160.dp)
                    .background(TertiaryGroupedBg),
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
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                val name = ProfileArticleCardText.authorName(author?.bestName, note.pubkey)
                AvatarImage(url = author?.pictureURL, pubkey = note.pubkey, size = 22.dp, displayName = name,
                    modifier = Modifier.clearAndSetSemantics {})
                Text(
                    text = name,
                    color = SecondaryText,
                    fontSize = 12.sp,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f, fill = false),
                )
                Dot()
                Text(
                    text = java.text.DateFormat.getDateInstance(java.text.DateFormat.MEDIUM).format(meta.publishedAt),
                    color = SecondaryText,
                    fontSize = 12.sp,
                    maxLines = 1,
                )
                if (locked) {
                    Dot()
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(3.dp)) {
                        Icon(NostrVaultIcons.Lock, contentDescription = null, tint = colors.primary, modifier = Modifier.size(12.dp))
                        Text("Locked", color = colors.primary, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, maxLines = 1)
                    }
                } else if (minutes != null) {
                    Dot()
                    Text("$minutes min read", color = SecondaryText, fontSize = 12.sp, maxLines = 1)
                }
            }
        }
        webLink?.let { link ->
            DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                DropdownMenuItem(
                    text = { Text(link.label) },
                    leadingIcon = { Icon(NostrVaultIcons.OpenExternal, contentDescription = null, modifier = Modifier.size(20.dp)) },
                    onClick = {
                        menuOpen = false
                        NostrWebLinks.open(context, link.url)
                    },
                )
            }
        }
    }
}

/** The footer's separator; not read aloud. */
@Composable
private fun Dot() {
    Text("·", color = SecondaryText, fontSize = 12.sp, modifier = Modifier.clearAndSetSemantics {})
}
