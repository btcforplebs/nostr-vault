package com.nostrvault.ui.screens.profile

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.*
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.layout
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.ui.theme.*

/**
 * One line, never scrolled: the labelled actions share the width and the
 * icon-only ones keep a fixed square. On narrow screens or with large text
 * Message drops its word first, then Zap. Block lives in ⋯, away from Message.
 */
@Composable
internal fun ProfileActionRow(
    isOwnProfile: Boolean,
    isFollowing: Boolean,
    isBlocked: Boolean,
    canZap: Boolean,
    zapSats: Int,
    onEditProfile: () -> Unit,
    onFollow: () -> Unit,
    onMessage: () -> Unit,
    onBlock: () -> Unit,
    onZap: () -> Unit,
    onZapLongPress: () -> Unit,
    onTrustWeb: () -> Unit,
    onCopyNpub: () -> Unit,
) {
    val colors = LocalNostrVaultColors.current
    val tint = colors.primary.copy(alpha = 0.12f)
    // Like SwiftUI's ViewThatFits: the first of the rows, each terser than the
    // last, whose natural width fits.
    @Composable
    fun buttons(compact: Int) {
        Row(
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth(),
        ) {
            if (isOwnProfile) {
                // Post is the floating button. Pulling the page down opens
                // Edit Profile too; the button stays for TalkBack and anyone
                // who has not found the pull.
                ActionChip("Edit Profile", NostrVaultIcons.Edit, colors.primary, tint, onClick = onEditProfile, modifier = Modifier.weight(1f))
                ActionIcon(NostrVaultIcons.WebOfTrust, "Web of Trust", colors.primary, tint, onClick = onTrustWeb)
            } else {
                ActionChip(
                    if (isFollowing) "Unfollow" else "Follow",
                    NostrVaultIcons.PersonAdd,
                    if (isFollowing) Color.White else colors.primary,
                    if (isFollowing) colors.primary else tint,
                    onClick = onFollow,
                    modifier = Modifier.weight(1f),
                )
                if (compact > 0) {
                    ActionIcon(NostrVaultIcons.Chat, "Message", colors.primary, tint, onClick = onMessage)
                } else {
                    ActionChip("Message", NostrVaultIcons.Chat, colors.primary, tint, onClick = onMessage, modifier = Modifier.weight(1f))
                }
                if (canZap) {
                    ActionChip(if (compact < 2) "Zap $zapSats" else "$zapSats", NostrVaultIcons.Zap, Color(0xFFFF9800), Color(0xFFFF9800).copy(alpha = 0.15f), onClick = onZap, onLongClick = onZapLongPress, longClickLabel = "Choose an amount", modifier = Modifier.weight(1f), description = "Zap $zapSats sats")
                }
                ActionIcon(NostrVaultIcons.WebOfTrust, "Web of Trust", colors.primary, tint, onClick = onTrustWeb)
                var menuOpen by remember { mutableStateOf(false) }
                Box {
                    ActionIcon(NostrVaultIcons.More, "More", colors.primary, tint, onClick = { menuOpen = true })
                    DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                        DropdownMenuItem(
                            text = { Text("Copy npub") },
                            leadingIcon = { Icon(NostrVaultIcons.Copy, contentDescription = null, modifier = Modifier.size(20.dp)) },
                            onClick = { menuOpen = false; onCopyNpub() },
                        )
                        HorizontalDivider()
                        val blockColor = if (isBlocked) Color(0xFFFF9800) else ErrorRed
                        DropdownMenuItem(
                            text = { Text(if (isBlocked) "Unblock" else "Block", color = blockColor) },
                            leadingIcon = { Icon(NostrVaultIcons.Blocked, contentDescription = null, tint = blockColor, modifier = Modifier.size(20.dp)) },
                            onClick = { menuOpen = false; onBlock() },
                        )
                    }
                }
            }
        }
    }
    androidx.compose.ui.layout.SubcomposeLayout(
        Modifier
            .fillMaxWidth()
            .padding(start = 16.dp, end = 16.dp, top = 14.dp),
    ) { constraints ->
        val rows = (0..2).map { level -> subcompose(level) { buttons(compact = level) }.first() }
        val chosen = rows.firstOrNull { it.maxIntrinsicWidth(constraints.maxHeight) <= constraints.maxWidth } ?: rows.last()
        val placeable = chosen.measure(constraints)
        layout(placeable.width, placeable.height) { placeable.place(0, 0) }
    }
}

@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
private fun ActionChip(
    label: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    contentColor: Color,
    background: Color,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    description: String = label,
    /** A long-press action, with a haptic tick (the zap chip's custom amount). */
    onLongClick: (() -> Unit)? = null,
    longClickLabel: String? = null,
) {
    val haptics = androidx.compose.ui.platform.LocalHapticFeedback.current
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterHorizontally),
        modifier = modifier
            .height(32.dp)
            .clip(RoundedCornerShape(6.dp))
            .background(background)
            .combinedClickable(
                onClick = onClick,
                onLongClick = onLongClick?.let { action ->
                    {
                        haptics.performHapticFeedback(androidx.compose.ui.hapticfeedback.HapticFeedbackType.LongPress)
                        action()
                    }
                },
                onLongClickLabel = longClickLabel,
            )
            .padding(horizontal = 10.dp),
    ) {
        Icon(icon, contentDescription = description, tint = contentColor, modifier = Modifier.size(14.dp))
        Text(label, color = contentColor, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, softWrap = false)
    }
}

@Composable
private fun ActionIcon(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    description: String,
    contentColor: Color,
    background: Color,
    onClick: () -> Unit,
) {
    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .size(width = 36.dp, height = 32.dp)
            .clip(RoundedCornerShape(6.dp))
            .background(background)
            .clickable(onClick = onClick),
    ) {
        Icon(icon, contentDescription = description, tint = contentColor, modifier = Modifier.size(16.dp))
    }
}
