package com.nostrvault.ui.screens

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.FeedNote
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.GatedArticle
import com.nostrvault.data.model.GatedArticleTeaser
import com.nostrvault.service.GatedArticleService
import com.nostrvault.ui.theme.*
import dev.jeziellago.compose.markdowntext.MarkdownText

internal fun gatedStatusText(authorName: String, priceSats: Int): String =
    "Locked by $authorName for $priceSats sats."

/**
 * The body of a gated article. A Fanfares article gets the pay-to-unlock card
 * ([FanfaresGatedArticleBody]). Any other gated article shows its teaser and
 * a lock card, or the article when this reader unlocked it before: Nostr
 * Vault does not unlock those (no pay button, no key request).
 */
@Composable
internal fun GatedArticleBody(
    note: FeedNote,
    gated: GatedArticle,
    service: GatedArticleService,
    author: FeedProfile?,
    bodyStyle: TextStyle,
) {
    if (gated.isFanfares) {
        FanfaresGatedArticleBody(note, gated, service, author, bodyStyle)
        return
    }
    val unlocked = remember(note.id, note.tags, service.activeReader) { service.storedBody(note, gated) }

    if (unlocked != null) {
        GatedUnlockedBody(unlocked, bodyStyle)
        return
    }
    GatedLockFrame(note, gated, bodyStyle) {
        Text(
            text = gatedStatusText(author?.bestName ?: "the author", gated.priceSats),
            color = SecondaryText,
            fontSize = 14.sp,
        )
    }
}

@Composable
internal fun GatedUnlockedBody(markdown: String, bodyStyle: TextStyle) {
    MarkdownText(
        markdown = markdown,
        style = bodyStyle,
        linkColor = LocalNostrVaultColors.current.primary,
        modifier = Modifier.fillMaxWidth(),
    )
}

/** The teaser, then the lock card: title row with the price, then [content]. */
@Composable
internal fun GatedLockFrame(
    note: FeedNote,
    gated: GatedArticle,
    bodyStyle: TextStyle,
    content: @Composable ColumnScope.() -> Unit,
) {
    val colors = LocalNostrVaultColors.current
    Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
        val teaser = GatedArticleTeaser.strip(note.content)
        val summary = com.nostrvault.data.model.ArticleMeta.from(note).summary
        if (teaser.isNotEmpty() && teaser != summary) {
            MarkdownText(markdown = teaser, style = bodyStyle, linkColor = colors.primary, modifier = Modifier.fillMaxWidth())
        }
        Surface(
            shape = RoundedCornerShape(14.dp),
            color = SecondaryGroupedBg,
            border = BorderStroke(1.dp, colors.primary.copy(alpha = 0.35f)),
        ) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Icon(Icons.Filled.Lock, contentDescription = null, tint = PrimaryText, modifier = Modifier.size(18.dp))
                    Text("Locked article", color = PrimaryText, fontSize = 16.sp, fontWeight = FontWeight.Bold,
                        modifier = Modifier.weight(1f))
                    Surface(shape = RoundedCornerShape(50), color = colors.primary.copy(alpha = 0.15f)) {
                        Text("${gated.priceSats} sats", color = colors.primary, fontSize = 13.sp,
                            fontWeight = FontWeight.SemiBold,
                            modifier = Modifier.padding(horizontal = 10.dp, vertical = 4.dp))
                    }
                }
                content()
            }
        }
    }
}
