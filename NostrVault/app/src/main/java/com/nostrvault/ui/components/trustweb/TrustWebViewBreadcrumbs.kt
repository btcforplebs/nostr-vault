package com.nostrvault.ui.components

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import com.nostrvault.data.model.FeedProfile

@Composable
internal fun TrustWebViewBreadcrumbs(
    modifier: Modifier,
    crumbs: List<String>,
    centerKey: String,
    author: String,
    profiles: Map<String, FeedProfile>,
    accent: Color,
    name: (String) -> String,
    jump: (Int) -> Unit,
    /** On the WOT tab the destination is always you, so its chip is left off (iOS). */
    isWOTTab: Boolean = false,
    /** Whose follows are still on their way: their chip spins (iOS). */
    loading: (String) -> Boolean = { false },
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        modifier = modifier.horizontalScroll(rememberScrollState()).padding(horizontal = 16.dp),
    ) {
        crumbs.forEachIndexed { index, pubkey ->
            if (index > 0) CrumbArrow()
            val on = index == crumbs.size - 1
            Chip(pubkey, name(pubkey), profiles[pubkey], on = on, destination = false, accent = accent,
                onClick = if (on) null else ({ jump(index) }), loading = loading(pubkey))
        }
        if (centerKey != author && !isWOTTab) {
            CrumbArrow()
            Chip(author, name(author), profiles[author], on = false, destination = true, accent = accent, onClick = null)
        }
    }
}
