package com.nostrvault.ui.screens.profile

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.*

/**
 * Lightning address, website and npub as one wrapping row of chips, in place
 * of a table row each. Tap copies, or opens the website (iOS #456 linksRow).
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun ProfileLinksRow(
    lightning: String?,
    website: String?,
    npub: String?,
    onCopyLightning: () -> Unit,
    onCopyNpub: () -> Unit,
) {
    val colors = LocalNostrVaultColors.current
    val uriHandler = androidx.compose.ui.platform.LocalUriHandler.current
    val copiedGreen = Color(0xFF4CAF50)
    FlowRow(
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier
            .fillMaxWidth()
            .padding(start = 16.dp, end = 16.dp, top = 12.dp),
    ) {
        lightning?.let { address ->
            var copied by remember { mutableStateOf(false) }
            CopiedReset(copied) { copied = false }
            LinkChip(
                text = address,
                icon = if (copied) NostrVaultIcons.Check else NostrVaultIcons.Zap,
                tint = if (copied) copiedGreen else Color(0xFFFF9800),
                description = if (copied) "Lightning address copied" else "Copy Lightning address $address",
                onClick = { onCopyLightning(); copied = true },
            )
        }
        website?.let { site ->
            val shown = site.removePrefix("https://").removePrefix("http://")
            LinkChip(
                text = shown,
                icon = NostrVaultIcons.Globe,
                tint = colors.primary,
                description = "Open $shown",
                onClick = { runCatching { uriHandler.openUri(if (site.startsWith("http")) site else "https://$site") } },
            )
        }
        npub?.let {
            var copied by remember { mutableStateOf(false) }
            CopiedReset(copied) { copied = false }
            LinkChip(
                text = "${it.take(12)}…${it.takeLast(8)}",
                icon = if (copied) NostrVaultIcons.Check else NostrVaultIcons.Key,
                tint = if (copied) copiedGreen else SecondaryText,
                description = if (copied) "Public key copied" else "Copy public key",
                onClick = { onCopyNpub(); copied = true },
            )
        }
    }
}

/** Puts a chip's checkmark back to its icon a moment after a copy. */
@Composable
private fun CopiedReset(copied: Boolean, reset: () -> Unit) {
    LaunchedEffect(copied) {
        if (copied) {
            kotlinx.coroutines.delay(1_500)
            reset()
        }
    }
}

@Composable
private fun LinkChip(
    text: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    tint: Color,
    description: String,
    onClick: () -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(5.dp),
        modifier = Modifier
            .height(26.dp)
            .clip(CircleShape)
            .background(SecondaryText.copy(alpha = 0.1f))
            .clickable(role = androidx.compose.ui.semantics.Role.Button, onClick = onClick)
            .semantics(mergeDescendants = true) { contentDescription = description }
            .padding(horizontal = 10.dp),
    ) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(11.dp))
        Text(
            text,
            color = PrimaryText.copy(alpha = 0.8f),
            fontSize = 12.sp,
            fontWeight = FontWeight.Medium,
            maxLines = 1,
            overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
        )
    }
}
