package com.nostrvault.ui.components

import androidx.compose.foundation.layout.*
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.*
import java.util.Locale

/** A post's place in the Popular feed as shown, from #1, and its engagement score. */
data class PopularRank(val rank: Int, val score: Double)

/**
 * "🔥 #3 · 1.2k" at the top of a post in the Popular feed. iOS: PopularRankLine
 * in PopularRankControls.swift.
 */
@Composable
fun PopularRankLine(ranked: PopularRank, modifier: Modifier = Modifier) {
    val score = formatPopularScore(ranked.score)
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(5.dp),
        modifier = modifier
            .padding(bottom = 6.dp)
            .clearAndSetSemantics { contentDescription = "Popular rank ${ranked.rank}, score $score" },
    ) {
        Icon(NostrVaultIcons.Popular, contentDescription = null, tint = ZapOrange, modifier = Modifier.size(13.dp))
        Text("#${ranked.rank}", color = PrimaryText, fontSize = 12.sp, fontWeight = FontWeight.Bold)
        Text("·", color = SecondaryText, fontSize = 12.sp)
        Text(score, color = SecondaryText, fontSize = 11.sp, fontWeight = FontWeight.Medium, fontFamily = FontFamily.Monospace)
    }
}

/** 1.2k from 1000 up, a whole number below (iOS PopularRankLine.formatted). */
fun formatPopularScore(score: Double): String =
    if (score >= 1000) String.format(Locale.US, "%.1fk", score / 1000) else String.format(Locale.US, "%.0f", score)
