package com.nostrvault.ui.components

import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.SecondaryText

/** What a bare repost's row says while it has no original to show. */
enum class RepostPlaceholder {
    /** The original is being fetched. */
    LOADING,
    /** No relay returned the original (deleted, or on none we ask). */
    UNAVAILABLE,
}

/**
 * The line a bare repost's row shows in place of the original's text. Without
 * the unavailable state it would say "Loading" forever (iOS #227).
 */
@Composable
fun RepostPlaceholderLine(placeholder: RepostPlaceholder, modifier: Modifier = Modifier) {
    Row(verticalAlignment = Alignment.CenterVertically, modifier = modifier) {
        if (placeholder == RepostPlaceholder.LOADING) {
            CircularProgressIndicator(
                color = SecondaryText,
                strokeWidth = 1.5.dp,
                modifier = Modifier.size(12.dp),
            )
            Spacer(Modifier.width(6.dp))
        }
        Text(
            text = when (placeholder) {
                RepostPlaceholder.LOADING -> "Loading reposted note…"
                RepostPlaceholder.UNAVAILABLE -> "The reposted note is unavailable"
            },
            color = SecondaryText,
            fontSize = 13.sp,
        )
    }
}
