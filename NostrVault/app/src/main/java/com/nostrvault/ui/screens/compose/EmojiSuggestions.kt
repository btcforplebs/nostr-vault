package com.nostrvault.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.service.CustomEmoji
import com.nostrvault.ui.components.CustomEmojiImage
import com.nostrvault.ui.theme.PrimaryText

/**
 * One row of custom emoji chips for the `:name` being typed, docked above
 * the toolbar like [MentionSuggestions]. iOS: ComposeView emoji strip.
 */
@Composable
internal fun EmojiSuggestions(
    results: List<CustomEmoji>,
    onSelect: (CustomEmoji) -> Unit,
    modifier: Modifier = Modifier,
) {
    LazyRow(
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        modifier = modifier.fillMaxWidth(),
    ) {
        items(results, key = { it.shortcode }) { emoji ->
            Surface(
                onClick = { onSelect(emoji) },
                color = Color(0xFF22222A),
                shape = RoundedCornerShape(50),
                modifier = Modifier
                    .height(44.dp)
                    .widthIn(max = 200.dp)
                    .semantics { contentDescription = "Insert ${emoji.content}" },
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.padding(start = 8.dp, end = 14.dp),
                ) {
                    CustomEmojiImage(emoji, size = 28.dp)
                    Spacer(Modifier.width(8.dp))
                    Text(
                        text = emoji.content,
                        color = PrimaryText,
                        fontSize = 14.sp,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
        }
    }
}
