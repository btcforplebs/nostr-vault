package com.nostrvault.ui.screens.live

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.height
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nostrvault.data.model.LiveStream
import com.nostrvault.relay.HavenBridge
import com.nostrvault.ui.screens.profile.ShareProfileSheet
import com.nostrvault.ui.theme.LocalNostrVaultColors
import com.nostrvault.ui.theme.NostrVaultIcons
import com.nostrvault.ui.theme.PrimaryText

/** Follow / Following for the stream's host, next to the title. */
@Composable
internal fun LiveFollowButton(following: Boolean, onToggle: () -> Unit) {
    val colors = LocalNostrVaultColors.current
    OutlinedButton(
        onClick = onToggle,
        contentPadding = PaddingValues(horizontal = 12.dp, vertical = 0.dp),
        colors = ButtonDefaults.outlinedButtonColors(contentColor = if (following) PrimaryText else colors.primary),
        modifier = Modifier.height(34.dp),
    ) {
        Text(if (following) "Following" else "Follow", fontSize = 13.sp)
    }
}

/**
 * The Share button: the stream as a note (the composer, prefilled, so nothing
 * goes out until Post), its nostrvault.app link to another app or the
 * clipboard, and the streamer's own profile, shared or opened.
 */
@Composable
internal fun LiveShareButton(
    stream: LiveStream,
    hostName: String?,
    onShareAsNote: () -> Unit,
    onOpenHost: () -> Unit,
    onCopied: () -> Unit,
) {
    val colors = LocalNostrVaultColors.current
    val context = LocalContext.current
    var menu by remember { mutableStateOf(false) }
    var shareProfile by remember { mutableStateOf(false) }
    Box {
        IconButton(onClick = { menu = true }) {
            Icon(NostrVaultIcons.Share, contentDescription = "Share stream", tint = colors.primary)
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            DropdownMenuItem(
                text = { Text("Share as a note") },
                leadingIcon = { Icon(NostrVaultIcons.Compose, contentDescription = null) },
                onClick = { menu = false; onShareAsNote() },
            )
            DropdownMenuItem(
                text = { Text("Share link…") },
                leadingIcon = { Icon(NostrVaultIcons.Share, contentDescription = null) },
                onClick = { menu = false; LiveStreamShare.share(context, stream) },
            )
            DropdownMenuItem(
                text = { Text("Copy link") },
                leadingIcon = { Icon(NostrVaultIcons.Copy, contentDescription = null) },
                onClick = {
                    menu = false
                    if (LiveStreamShare.copyLink(context, stream)) onCopied()
                },
            )
            DropdownMenuItem(
                text = { Text("Share streamer's profile") },
                leadingIcon = { Icon(NostrVaultIcons.Profile, contentDescription = null) },
                onClick = { menu = false; shareProfile = true },
            )
            DropdownMenuItem(
                text = { Text("Open streamer's profile") },
                leadingIcon = { Icon(NostrVaultIcons.Profile, contentDescription = null) },
                onClick = { menu = false; onOpenHost() },
            )
        }
    }
    if (shareProfile) {
        val npub = remember(stream.hostPubkey) { HavenBridge.hexToNpub(stream.hostPubkey) }
        if (npub == null) shareProfile = false
        else ShareProfileSheet(npub = npub, name = hostName, onDismiss = { shareProfile = false })
    }
}
