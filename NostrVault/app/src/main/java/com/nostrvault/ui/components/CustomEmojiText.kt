package com.nostrvault.ui.components

import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.InlineTextContent
import androidx.compose.foundation.text.appendInlineContent
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.Placeholder
import androidx.compose.ui.text.PlaceholderVerticalAlign
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import com.nostrvault.service.CustomEmoji

/** The inline-content id for one shortcode in a note's text. */
private const val EMOJI_ID_PREFIX = "nip30:"

/**
 * [text] with `:shortcode:` that [emojis] has images for put in as inline
 * content, read out as the shortcode. The rest keeps its inline markdown.
 */
internal fun AnnotatedString.Builder.appendTextWithEmoji(text: String, emojis: Map<String, CustomEmoji>) {
    for (segment in CustomEmoji.segments(text, emojis)) {
        when (segment) {
            is CustomEmoji.Segment.Text -> appendInlineMarkdown(segment.text)
            is CustomEmoji.Segment.Emoji ->
                appendInlineContent(EMOJI_ID_PREFIX + segment.emoji.shortcode, segment.emoji.content)
        }
    }
}

/**
 * An image per shortcode in [emojis], each a little over a line of text
 * tall, for the ids [appendTextWithEmoji] puts in. Empty with no emoji.
 */
internal fun customEmojiInlineContent(emojis: Map<String, CustomEmoji>): Map<String, InlineTextContent> =
    emojis.values.associate { emoji ->
        (EMOJI_ID_PREFIX + emoji.shortcode) to
            InlineTextContent(Placeholder(1.25.em, 1.25.em, PlaceholderVerticalAlign.TextCenter)) {
                // The placeholder's size bounds it; 64dp only asks for "as big as that".
                CustomEmojiImage(emoji, size = 64.dp)
            }
    }

/** A [BasicText] that reports the character a tap lands on, as ClickableText does. */
@Composable
internal fun TappableEmojiText(
    text: AnnotatedString,
    inlineContent: Map<String, InlineTextContent>,
    style: TextStyle,
    modifier: Modifier = Modifier,
    onClick: (Int) -> Unit,
) {
    var layout by remember { mutableStateOf<TextLayoutResult?>(null) }
    val currentClick by rememberUpdatedState(onClick)
    BasicText(
        text = text,
        style = style,
        inlineContent = inlineContent,
        onTextLayout = { layout = it },
        modifier = modifier.pointerInput(Unit) {
            detectTapGestures { position ->
                layout?.let { currentClick(it.getOffsetForPosition(position)) }
            }
        },
    )
}
