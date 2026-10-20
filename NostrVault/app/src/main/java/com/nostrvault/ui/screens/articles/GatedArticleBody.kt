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
 * The teaser and a lock card, or the article when this reader unlocked it
 * before. Nostr Vault does not unlock articles: no pay button, no key request.
 */
@Composable
internal fun GatedArticleBody(
    note: FeedNote,
    gated: GatedArticle,
    service: GatedArticleService,
    author: FeedProfile?,
    bodyStyle: TextStyle,
) {
    val colors = LocalNostrVaultColors.current
    val unlocked = remember(note.id, note.tags, service.activeReader) { service.open(note, gated) }

    if (unlocked != null) {
        MarkdownText(
            markdown = unlocked,
            style = bodyStyle,
            linkColor = colors.primary,
            modifier = Modifier.fillMaxWidth(),
        )
        return
    }

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
                Text(
                    text = gatedStatusText(author?.bestName ?: "the author", gated.priceSats),
                    color = SecondaryText,
                    fontSize = 14.sp,
                )
            }
        }
    }
}
