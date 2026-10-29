package com.nostrvault.ui.screens.live

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil.compose.AsyncImage
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.service.LiveChatService
import com.nostrvault.ui.components.AvatarImage
import com.nostrvault.ui.screens.dm.DMAttachment
import com.nostrvault.ui.theme.*

/**
 * The room. Chat lines and zaps share one list because that is how a live
 * audience experiences them — a 5,000 sat zap is a louder message, not a
 * separate feature.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
internal fun LiveChat(
    messages: List<LiveChatService.ChatEntry>,
    profiles: Map<String, FeedProfile>,
    /** Long-press a line to report it. */
    onReport: (LiveChatService.ChatEntry) -> Unit,
    /** A tap on a name or picture, and View profile in the line's menu. */
    onOpenProfile: (String) -> Unit = {},
    /** Mute in the line's menu: the app's mute, so the chatter is hidden everywhere. */
    onMute: (String) -> Unit = {},
    /** Lines drawn over the video in full screen: no padding of their own to spare. */
    compact: Boolean = false,
    modifier: Modifier = Modifier,
) {
    val colors = LocalNostrVaultColors.current
    val listState = rememberLazyListState()

    // Follow the conversation, the way every chat does.
    LaunchedEffect(messages.size) {
        if (messages.isNotEmpty()) listState.animateScrollToItem(messages.lastIndex)
    }

    if (messages.isEmpty()) {
        Box(contentAlignment = Alignment.Center, modifier = modifier.fillMaxWidth()) {
            Text("No messages yet. Say hello.", color = SecondaryText, fontSize = 13.sp)
        }
        return
    }

    // iOS: 8 between rows, 10 above and below the list.
    LazyColumn(
        state = listState,
        contentPadding = PaddingValues(vertical = 6.dp),
        modifier = modifier.fillMaxWidth(),
    ) {
        items(messages, key = { it.id }) { entry ->
            val name = profiles[entry.pubkey]?.bestName ?: entry.pubkey.take(8)
            var showMenu by remember { mutableStateOf(false) }
            Box {
                // iOS LiveChatRowView: a 26 avatar, then the name and time over
                // the text, with a zap shown as an orange capsule on a tinted row.
                val isZap = entry.zapSats != null
                Row(
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    modifier = Modifier
                        .fillMaxWidth()
                        .combinedClickable(
                            onClick = {},
                            onLongClick = { showMenu = true },
                            onLongClickLabel = "Message options",
                        )
                        .padding(horizontal = if (compact) 8.dp else 16.dp, vertical = if (compact) 2.dp else 4.dp)
                        .then(
                            if (isZap) {
                                Modifier
                                    .clip(RoundedCornerShape(8.dp))
                                    .background(ZapOrange.copy(alpha = 0.12f))
                                    .padding(8.dp)
                            } else Modifier,
                        ),
                ) {
                    AvatarImage(
                        url = profiles[entry.pubkey]?.pictureURL,
                        pubkey = entry.pubkey,
                        size = if (compact) 20.dp else 26.dp,
                        displayName = name,
                        modifier = Modifier.clickable(onClickLabel = "Open $name's profile") { onOpenProfile(entry.pubkey) },
                    )
                    // Image links come out of the text and show as pictures
                    // under it, whoever sent them.
                    val parts = remember(entry.content) { DMAttachment.split(entry.content) }
                    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Row(
                            horizontalArrangement = Arrangement.spacedBy(6.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            if (entry.zapSats != null) {
                                Text(
                                    // A zap whose amount the receipt did not carry still
                                    // happened — show the bolt, not a zero.
                                    text = if (entry.zapSats > 0) "⚡ ${entry.zapSats}" else "⚡",
                                    color = Color.Black,
                                    fontSize = 10.sp,
                                    fontWeight = FontWeight.Bold,
                                    modifier = Modifier
                                        .clip(CircleShape)
                                        .background(ZapOrange.copy(alpha = 0.9f))
                                        .padding(horizontal = 6.dp, vertical = 2.dp),
                                )
                            }
                            Text(
                                text = name,
                                color = PrimaryText,
                                fontSize = 12.sp,
                                fontWeight = FontWeight.SemiBold,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                                modifier = Modifier
                                    .weight(1f, fill = false)
                                    .clickable(onClickLabel = "Open $name's profile") { onOpenProfile(entry.pubkey) },
                            )
                            Text(
                                text = remember(entry.createdAt) { chatTime(entry.createdAt) },
                                color = SecondaryText,
                                fontSize = 10.sp,
                            )
                        }
                        if (parts.text.isNotEmpty()) {
                            Text(
                                text = parts.text,
                                color = PrimaryText,
                                fontSize = 13.sp,
                                lineHeight = 18.sp,
                            )
                        }
                        parts.images.forEach { url ->
                            AsyncImage(
                                model = url,
                                contentDescription = null,
                                contentScale = ContentScale.Crop,
                                modifier = Modifier
                                    .padding(top = 4.dp)
                                    .size(180.dp)
                                    .clip(RoundedCornerShape(10.dp)),
                            )
                        }
                    }
                }
                DropdownMenu(expanded = showMenu, onDismissRequest = { showMenu = false }) {
                    DropdownMenuItem(
                        text = { Text("View profile") },
                        leadingIcon = { Icon(NostrVaultIcons.Profile, contentDescription = null) },
                        onClick = {
                            showMenu = false
                            onOpenProfile(entry.pubkey)
                        },
                    )
                    DropdownMenuItem(
                        text = { Text("Mute $name") },
                        leadingIcon = { Icon(NostrVaultIcons.Blocked, contentDescription = null) },
                        onClick = {
                            showMenu = false
                            onMute(entry.pubkey)
                        },
                    )
                    DropdownMenuItem(
                        text = { Text("Report message") },
                        leadingIcon = { Icon(NostrVaultIcons.Alert, contentDescription = null) },
                        onClick = {
                            showMenu = false
                            onReport(entry)
                        },
                    )
                }
            }
        }
    }
}

/** A chat line's time, short style in the phone's locale (iOS `timeStyle = .short`). */
private fun chatTime(createdAtSecs: Long): String =
    java.text.DateFormat.getTimeInstance(java.text.DateFormat.SHORT).format(java.util.Date(createdAtSecs * 1000))
