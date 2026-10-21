package com.nostrvault.ui.components

import com.nostrvault.data.model.TrustPathText
import androidx.compose.ui.platform.LocalContext
import com.nostrvault.ui.theme.ErrorRed
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.PersonRemove
import androidx.compose.material.icons.outlined.DoNotTouch
import androidx.compose.material.icons.outlined.Explore
import androidx.compose.material.icons.outlined.PanTool
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.TrustPath
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.PrimaryText
import com.nostrvault.ui.theme.SecondaryText
import com.nostrvault.ui.theme.Surface2
import kotlin.math.max

/**
 * The WOT tab's "can I trust them?" card: who they are, the people you follow
 * who follow them (the post card's answer and words), and what you can do
 * about it. Block sits behind ⋯ so it can't be hit by accident. iOS
 * `trustCard`.
 */
@Composable
internal fun TrustCard(
    pubkey: String,
    name: (String) -> String,
    profiles: Map<String, FeedProfile>,
    path: TrustPath?,
    following: Boolean,
    blocked: Boolean,
    accent: Color,
    onClose: () -> Unit,
    onFollow: () -> Unit,
    onMessage: (() -> Unit)?,
    onProfile: (() -> Unit)?,
    onSeeWeb: (() -> Unit)?,
    onBlock: () -> Unit,
    modifier: Modifier = Modifier,
    /**
     * A profile's or a post's globe is a look, not a place to explore: its
     * card has this one button, which shows them in the WOT tab (Logen, 10/15).
     */
    onOpenInWot: (() -> Unit)? = null,
) {
    val shape = RoundedCornerShape(16.dp)
    var moreOpen by remember { mutableStateOf(false) }
    Column(
        verticalArrangement = Arrangement.spacedBy(12.dp),
        modifier = modifier
            .padding(12.dp)
            .widthIn(max = 520.dp)
            .fillMaxWidth()
            .shadow(16.dp, shape)
            .clip(shape)
            .background(Surface2.copy(alpha = 0.96f))
            .padding(14.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            val profile = profiles[pubkey]
            AvatarImage(url = profile?.pictureURL, pubkey = pubkey, size = 44.dp, displayName = profile?.bestName)
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(name(pubkey), color = PrimaryText, fontSize = 17.sp, fontWeight = FontWeight.SemiBold,
                    maxLines = 1, overflow = TextOverflow.Ellipsis)
                profile?.nip05?.takeIf { it.isNotBlank() }?.let {
                    Text(it, color = SecondaryText, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
            IconButton(onClick = onClose, modifier = Modifier.size(36.dp)) {
                Box(
                    Modifier.size(30.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.08f)),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(NostrVaultIcons.Dismiss, contentDescription = "Close", tint = SecondaryText, modifier = Modifier.size(16.dp))
                }
            }
        }
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            val bridges = path?.bridges.orEmpty()
            if (bridges.isNotEmpty()) {
                Row(horizontalArrangement = Arrangement.spacedBy((-10).dp), modifier = Modifier.clearAndSetSemantics { }) {
                    for (bridge in bridges) {
                        val profile = profiles[bridge]
                        AvatarImage(url = profile?.pictureURL, pubkey = bridge, size = 26.dp, displayName = profile?.bestName,
                            modifier = Modifier.border(2.dp, Color.Black.copy(alpha = 0.6f), CircleShape))
                    }
                }
            }
            Text(
                TrustPathText.label(path, name),
                color = if (path?.reach == TrustPath.Reach.OUTSIDE) SecondaryText else PrimaryText.copy(alpha = 0.85f),
                fontSize = 13.sp,
                modifier = Modifier.weight(1f),
            )
        }
        // Brainstorm, so their trust can be checked off the device.
        val context = LocalContext.current
        val webLink = remember(pubkey) { NostrWebLinks.forProfile(pubkey) }
        if (onOpenInWot != null) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
                CardButton("Open in WoT", icon = NostrVaultIcons.WebOfTrust, filled = true, accent = accent,
                    onClick = onOpenInWot, modifier = Modifier.weight(1f))
                webLink?.let { link ->
                    CardButton(link.label, short = "Brainstorm", icon = NostrVaultIcons.OpenExternal, filled = false,
                        accent = accent, onClick = { NostrWebLinks.open(context, link.url) }, modifier = Modifier.weight(1f))
                }
            }
        } else Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            modifier = Modifier.padding(start = 4.dp),
        ) {
            // The profile page's words: Unfollow says what the tap does.
            // Equal widths and an icon each, as on iOS.
            CardButton(if (following) "Unfollow" else "Follow", filled = !following, accent = accent,
                icon = if (following) Icons.Filled.PersonRemove else NostrVaultIcons.PersonAdd,
                onClick = onFollow, modifier = Modifier.weight(1f))
            if (onProfile != null) {
                CardButton("Profile", icon = NostrVaultIcons.AccountCircle, filled = false, accent = accent,
                    onClick = onProfile, modifier = Modifier.weight(1f))
            }
            if (onSeeWeb != null) {
                CardButton("See their web", short = "Their web", icon = NostrVaultIcons.WebOfTrust, filled = false,
                    accent = accent, onClick = onSeeWeb, modifier = Modifier.weight(1f))
            }
            Box {
                IconButton(onClick = { moreOpen = true }, modifier = Modifier.size(40.dp)) {
                    Box(
                        Modifier.size(width = 40.dp, height = 38.dp).clip(RoundedCornerShape(50)).background(Color.White.copy(alpha = 0.08f)),
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(NostrVaultIcons.More, contentDescription = "More", tint = SecondaryText, modifier = Modifier.size(18.dp))
                    }
                }
                // iOS: Message and the web link, one divider, then Block.
                DropdownMenu(expanded = moreOpen, onDismissRequest = { moreOpen = false }) {
                    if (onMessage != null) {
                        DropdownMenuItem(
                            text = { Text("Message", color = PrimaryText) },
                            leadingIcon = { MenuIcon(NostrVaultIcons.Chat, PrimaryText) },
                            onClick = {
                                moreOpen = false
                                onMessage()
                            },
                        )
                    }
                    webLink?.let { link ->
                        DropdownMenuItem(
                            text = { Text(link.label, color = PrimaryText) },
                            // iOS safari: a compass.
                            leadingIcon = { MenuIcon(Icons.Outlined.Explore, PrimaryText) },
                            onClick = {
                                moreOpen = false
                                NostrWebLinks.open(context, link.url)
                            },
                        )
                    }
                    HorizontalDivider()
                    val blockTint = if (blocked) PrimaryText else ErrorRed
                    DropdownMenuItem(
                        text = { Text(if (blocked) "Unblock" else "Block", color = blockTint) },
                        // iOS hand.raised / hand.raised.slash.
                        leadingIcon = { MenuIcon(if (blocked) Icons.Outlined.DoNotTouch else Icons.Outlined.PanTool, blockTint) },
                        onClick = {
                            moreOpen = false
                            onBlock()
                        },
                    )
                }
            }
        }
    }
}

@Composable
private fun CardButton(
    title: String,
    filled: Boolean,
    accent: Color,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    /** Stands in for [title] when a narrow phone has no room for it. */
    short: String? = null,
    icon: ImageVector? = null,
) {
    val tint = if (filled) Color.White else accent
    BoxWithConstraints(
        contentAlignment = Alignment.Center,
        modifier = modifier
            .height(38.dp)
            .clip(RoundedCornerShape(50))
            .background(if (filled) accent else Color.White.copy(alpha = 0.08f))
            .clickable(role = Role.Button, onClickLabel = title, onClick = onClick)
            .clearAndSetSemantics { contentDescription = title; role = Role.Button },
    ) {
        // Roughly 8.5dp a character at 14sp semibold, plus the icon and its gap.
        val room = maxWidth - (if (icon != null) 18.dp else 0.dp) - 12.dp
        val label = if (short != null && room < (title.length * 8.5f).dp) short else title
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
            // iOS: a 12pt symbol or a 13pt image.
            if (icon != null) Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(13.dp))
            Text(label, color = tint, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, maxLines = 1)
        }
    }
}

/** A ⋯ menu row's icon, iOS `Label(systemImage:)`. */
@Composable
private fun MenuIcon(icon: ImageVector, tint: Color) {
    Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(18.dp))
}
