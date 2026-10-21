package com.nostrvault.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.graphics.Color
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.outlined.FavoriteBorder
import androidx.compose.material.icons.outlined.ChatBubbleOutline
import androidx.compose.material.icons.outlined.Bolt
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.outlined.BorderColor
import androidx.compose.material.icons.outlined.Share
import com.nostrvault.ui.components.engagementCountLabel
import com.nostrvault.ui.components.LocalShowZapButton
import com.nostrvault.ui.components.formatCount
import androidx.compose.ui.unit.dp
import com.nostrvault.ui.theme.*

@Composable
internal fun ArticleActionBar(
    liked: Boolean,
    zapped: Boolean,
    likeCount: Int,
    commentCount: Int,
    zapSats: Long,
    highlighting: Boolean,
    onLike: () -> Unit,
    onComment: () -> Unit,
    onZap: () -> Unit,
    onHighlight: () -> Unit,
    onShare: () -> Unit,
    /** "Open in <site>", last in the bar (iOS ArticleReaderView); null when the article has no web address. */
    openWebLabel: String? = null,
    onOpenWeb: () -> Unit = {},
) {
    val colors = LocalNostrVaultColors.current
    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        ActionPill(if (liked) Icons.Filled.Favorite else Icons.Outlined.FavoriteBorder, "Like",
            if (liked) Color(0xFFE5484D) else SecondaryText, onLike, count = engagementCountLabel(likeCount))
        ActionPill(Icons.Outlined.ChatBubbleOutline, "Comment", SecondaryText, onComment,
            count = engagementCountLabel(commentCount))
        // Hidden, count and all, when ⚡️ is out of Appearance → Post buttons (iOS ArticleReaderView).
        if (LocalShowZapButton.current) ActionPill(if (zapped) Icons.Filled.Bolt else Icons.Outlined.Bolt, "Zap",
            // Orange only for your own zap; other people's show as the count.
            if (zapped) Color(0xFFF5A623) else SecondaryText, onZap,
            count = zapSats.takeIf { it > 0 }?.let { formatCount(it) })
        ActionPill(Icons.Outlined.BorderColor, "Highlight",
            if (highlighting) colors.primary else SecondaryText, onHighlight)
        ActionPill(Icons.Outlined.Share, "Share", SecondaryText, onShare)
        if (openWebLabel != null) ActionPill(NostrVaultIcons.OpenExternal, openWebLabel, SecondaryText, onOpenWeb)
    }
}
