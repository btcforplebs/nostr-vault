package com.nostrvault.ui.components

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.PersonRemove
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import com.nostrvault.ui.notification.LocalNotificationManager
import com.nostrvault.ui.notification.PillTone
import androidx.compose.ui.semantics.contentDescription
import com.nostrvault.ui.theme.*

/**
 * What tapping an avatar offers in the feed: Follow/Unfollow, Web of Trust
 * (where the screen offers it) and Block, the iOS FeedView avatar toolbar. Without it
 * an avatar tap opens the profile, as on screens that pass none.
 */
@Stable
class AvatarMenuActions(
    /** Your own avatar opens your profile instead; there is no one to follow or block. */
    val isOwn: (String) -> Boolean,
    val isFollowed: (String) -> Boolean,
    val onFollow: (String) -> Unit,
    val onUnfollow: (String) -> Unit,
    val onBlock: (String) -> Unit,
)

/**
 * The menu wired straight to [feedService], for screens outside the main
 * feed (search, hashtags, threads, profiles). Follow shows its banner and
 * Block publishes the mute list, as from the feed.
 */
fun avatarMenuActions(feedService: com.nostrvault.service.FeedService, isOwn: (String) -> Boolean) =
    AvatarMenuActions(
        isOwn = isOwn,
        isFollowed = feedService::isFollowing,
        onFollow = { feedService.followUser(it) },
        onUnfollow = { feedService.unfollowUser(it) },
        onBlock = feedService::blockUser,
    )

/**
 * [content] (an avatar) that opens the [menu] for [pubkey] when tapped, or
 * the profile when there is no menu or the avatar is your own.
 */
@Composable
internal fun AvatarWithMenu(
    pubkey: String,
    displayName: String,
    menu: AvatarMenuActions?,
    onProfileClick: (String) -> Unit,
    /** Opens the globe on [pubkey]: the post footer's old WoT button. */
    onTrustWeb: ((String) -> Unit)? = null,
    content: @Composable (Modifier) -> Unit,
) {
    if (menu == null || menu.isOwn(pubkey)) {
        content(Modifier.clickable { onProfileClick(pubkey) })
        return
    }
    var expanded by remember { mutableStateOf(false) }
    val lane = LocalNotificationManager.current
    Box {
        content(Modifier.clickable(onClickLabel = "Actions for $displayName") { expanded = true })
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            val followed = menu.isFollowed(pubkey)
            DropdownMenuItem(
                text = { Text(if (followed) "Unfollow" else "Follow", color = PrimaryText) },
                leadingIcon = {
                    Icon(
                        imageVector = if (followed) Icons.Filled.PersonRemove else NostrVaultIcons.PersonAdd,
                        contentDescription = null,
                        tint = if (followed) Color(0xFFFFCC00) else SuccessGreen,
                    )
                },
                onClick = {
                    expanded = false
                    if (followed) menu.onUnfollow(pubkey) else menu.onFollow(pubkey)
                },
            )
            if (onTrustWeb != null) {
                DropdownMenuItem(
                    text = { Text("Web of Trust", color = PrimaryText) },
                    leadingIcon = { Icon(NostrVaultIcons.TabWoT, contentDescription = null, tint = LocalNostrVaultColors.current.primary) },
                    onClick = {
                        expanded = false
                        onTrustWeb(pubkey)
                    },
                )
            }
            // Block last and set apart, so it's never a slip from the globe.
            HorizontalDivider()
            DropdownMenuItem(
                text = { Text("Block", color = ErrorRed) },
                leadingIcon = { Icon(NostrVaultIcons.Blocked, contentDescription = null, tint = ErrorRed) },
                onClick = {
                    expanded = false
                    menu.onBlock(pubkey)
                    // Hidden from you now: grey, not green (docs/pills.md).
                    lane.showToast("Blocked $displayName", PillTone.NEUTRAL)
                },
            )
        }
    }
}
