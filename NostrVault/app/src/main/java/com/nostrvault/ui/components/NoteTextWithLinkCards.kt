package com.nostrvault.ui.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.service.CustomEmoji
import com.nostrvault.data.model.NoteLinkSegments
import com.nostrvault.ui.theme.PrimaryText

/**
 * A note's text with each link's preview card at the spot the link was
 * written (iOS #1246), not piled under the note. [cards] are the links that
 * get a card; links past the cap stay in the text as ordinary links.
 */
@Composable
fun NoteTextWithLinkCards(
    content: String,
    cards: List<String>,
    profiles: Map<String, FeedProfile>,
    mediaURLs: Set<String> = emptySet(),
    onProfileClick: (String) -> Unit = {},
    onPlainTextClick: (() -> Unit)? = null,
    textColor: Color = PrimaryText,
    fontSize: TextUnit = 15.sp,
    lineHeight: TextUnit = 21.sp,
    selectable: Boolean = false,
    emojis: Map<String, CustomEmoji> = emptyMap(),
) {
    val segments = remember(content, cards) { NoteLinkSegments.split(content, cards) }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        for (segment in segments) {
            when (segment) {
                is NoteLinkSegments.Segment.Text -> NostrContentText(
                    content = segment.text,
                    profiles = profiles,
                    mediaURLs = mediaURLs,
                    onProfileClick = onProfileClick,
                    onPlainTextClick = onPlainTextClick,
                    textColor = textColor,
                    fontSize = fontSize,
                    lineHeight = lineHeight,
                    selectable = selectable,
                    emojis = emojis,
                )
                is NoteLinkSegments.Segment.Link -> LinkPreviewCard(url = segment.url)
            }
        }
    }
}
