package com.nostrvault.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.ArticleHighlight
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.ui.theme.*

/** The highlights behind one tinted passage: inline "Highlights" title, Done, the rows (iOS ArticleReaderView sheet). */
@Composable
internal fun HighlightsSheetContent(
    highlights: List<ArticleHighlight>,
    profiles: Map<String, FeedProfile>,
    onDone: () -> Unit,
    onComment: (ArticleHighlight) -> Unit,
) {
    val colors = LocalNostrVaultColors.current
    Column {
        Box(modifier = Modifier.fillMaxWidth().padding(horizontal = 8.dp)) {
            Text(
                "Highlights",
                color = PrimaryText,
                fontSize = 17.sp,
                fontWeight = FontWeight.SemiBold,
                textAlign = TextAlign.Center,
                modifier = Modifier.align(Alignment.Center),
            )
            TextButton(onClick = onDone, modifier = Modifier.align(Alignment.CenterEnd)) {
                Text("Done", color = colors.primary, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
            }
        }
        Column(
            verticalArrangement = Arrangement.spacedBy(14.dp),
            modifier = Modifier
                .verticalScroll(rememberScrollState())
                .padding(20.dp),
        ) {
            highlights.forEach { h -> HighlightRow(h, profiles[h.pubkey], onComment = { onComment(h) }) }
        }
    }
}
