package com.nostrvault.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.FeedHighlight
import com.nostrvault.data.model.FeedNote
import com.nostrvault.ui.theme.*

/**
 * A NIP-84 highlight in a timeline: the highlighter's comment, the passage
 * set off by a bar, and a web source as a link card. An article or note it
 * came from is one of [FeedNote.quotedEventIds], so the row's quote section
 * draws it under this. The text path drew the passage as if the highlighter
 * wrote it, with nothing saying where it came from. iOS HighlightInlineBody.
 */
@Composable
internal fun HighlightInlineBody(
    note: FeedNote,
    isFocused: Boolean,
    modifier: Modifier = Modifier,
) {
    val comment = remember(note.id, note.tags) { FeedHighlight.comment(note.tags) }
    val sourceURL = remember(note.id, note.tags) { FeedHighlight.sourceURL(note.tags) }
    val accent = LocalNostrVaultColors.current.primary
    Column(
        verticalArrangement = Arrangement.spacedBy(8.dp),
        modifier = modifier.fillMaxWidth().padding(top = 4.dp),
    ) {
        if (comment != null) {
            SelectionContainer {
                Text(text = comment, color = PrimaryText, fontSize = 17.sp, lineHeight = 24.sp)
            }
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(
                imageVector = NostrVaultIcons.Quote,
                contentDescription = null,
                tint = SecondaryText,
                modifier = Modifier.size(12.dp),
            )
            Spacer(Modifier.width(5.dp))
            Text(text = "Highlighted", color = SecondaryText, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
        }
        Row(Modifier.height(IntrinsicSize.Min)) {
            Box(
                Modifier
                    .width(3.dp)
                    .fillMaxHeight()
                    .background(accent.copy(alpha = 0.7f), RoundedCornerShape(1.5.dp)),
            )
            Spacer(Modifier.width(12.dp))
            SelectionContainer {
                Text(
                    text = note.content.trim(),
                    color = PrimaryText,
                    fontSize = if (isFocused) 19.sp else 17.sp,
                    lineHeight = if (isFocused) 27.sp else 24.sp,
                    fontFamily = FontFamily.Serif,
                    fontStyle = FontStyle.Italic,
                    maxLines = if (isFocused) Int.MAX_VALUE else 8,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        if (sourceURL != null) LinkPreviewCard(url = sourceURL)
    }
}
