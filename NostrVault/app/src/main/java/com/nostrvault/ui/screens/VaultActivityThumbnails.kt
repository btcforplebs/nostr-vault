package com.nostrvault.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil.compose.AsyncImage
import com.nostrvault.ui.components.FullScreenMediaRouter
import com.nostrvault.ui.theme.TertiaryGroupedBg

private const val SHOWN = 3

/**
 * The pictures in a Vault-list line, as a tight row of small squares under its
 * words. Three at most; the last one counts the rest. A tap opens the media
 * viewer on that picture, with the line's others there to swipe. iOS
 * VaultActivityThumbnails.
 */
@Composable
internal fun VaultActivityThumbnails(urls: List<String>, modifier: Modifier = Modifier) {
    val visible = urls.take(SHOWN)
    val hidden = urls.size - visible.size
    val shape = RoundedCornerShape(8.dp)
    Row(
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        modifier = modifier.semantics(mergeDescendants = true) {
            contentDescription = if (urls.size == 1) "1 picture" else "${urls.size} pictures"
        },
    ) {
        visible.forEachIndexed { index, url ->
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .size(56.dp)
                    .clip(shape)
                    .background(TertiaryGroupedBg)
                    .clickable { FullScreenMediaRouter.open(urls, index) },
            ) {
                AsyncImage(
                    model = url,
                    contentDescription = null,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier.size(56.dp),
                )
                if (hidden > 0 && index == visible.size - 1) {
                    Box(
                        contentAlignment = Alignment.Center,
                        modifier = Modifier.size(56.dp).background(Color.Black.copy(alpha = 0.45f)),
                    ) {
                        Text("+$hidden", color = Color.White, fontSize = 13.sp, fontWeight = FontWeight.Bold)
                    }
                }
            }
        }
    }
}
