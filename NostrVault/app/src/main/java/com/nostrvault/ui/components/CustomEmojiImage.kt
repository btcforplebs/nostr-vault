package com.nostrvault.ui.components

import androidx.compose.foundation.layout.size
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import coil.compose.AsyncImage
import coil.request.ImageRequest
import com.nostrvault.service.CustomEmoji

/** A NIP-30 custom emoji's image, square, read out as its shortcode. */
@Composable
fun CustomEmojiImage(emoji: CustomEmoji, size: Dp, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    AsyncImage(
        model = remember(emoji.url) { ImageRequest.Builder(context).data(emoji.url).build() },
        contentDescription = null,
        contentScale = ContentScale.Fit,
        modifier = modifier
            .size(size)
            .semantics { contentDescription = emoji.content },
    )
}

/**
 * One reaction as the app draws it: [custom]'s image when it has one, else
 * [emoji] as text. [fontSize] sizes both, so a custom emoji sits in a row
 * of Unicode ones at the same height.
 */
@Composable
fun ReactionGlyph(emoji: String, custom: CustomEmoji?, fontSize: TextUnit, modifier: Modifier = Modifier) {
    if (custom != null) {
        CustomEmojiImage(custom, size = (fontSize.value * 1.25f).dp, modifier = modifier)
    } else {
        Text(emoji, fontSize = fontSize, modifier = modifier)
    }
}
